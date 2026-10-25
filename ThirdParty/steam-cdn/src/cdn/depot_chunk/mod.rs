use std::io::{Cursor, Read};
use zip::ZipArchive;

use crate::{
    crypto::aes256::{self, IV_LENGTH},
    utils::lzma,
    Error,
};

pub async fn decrypt_and_decompress(data: &mut [u8], key: [u8; 32]) -> Result<Vec<u8>, Error> {
    if data.len() <= IV_LENGTH || data.len() % IV_LENGTH != 0 {
        return Err(Error::ChunkDecrypt);
    }

    let decrypted = aes256::decrypt_cbc_with_iv_extraction(data, key).map_err(|_| Error::ChunkDecrypt)?;
    if decrypted.starts_with(b"VSZa") {
        crate::utils::vzstd::decompress(&decrypted)
    } else if lzma::is_vz(&decrypted) {
        lzma::decompress(&decrypted).await.map_err(|_| Error::ChunkDecompress)
    } else if decrypted.starts_with(b"PK\x03\x04") {
        let cursor = Cursor::new(decrypted);
        let mut archive = ZipArchive::new(cursor).map_err(|_| Error::ChunkDecompress)?;
        if archive.len() != 1 { return Err(Error::ChunkDecompress); }
        let member = archive.by_index(0).map_err(|_| Error::ChunkDecompress)?;
        const MAX_CHUNK_OUTPUT: u64 = 4 * 1024 * 1024;
        if member.size() > MAX_CHUNK_OUTPUT {
            return Err(Error::ChunkSize);
        }
        let declared_size = member.size();
        let mut buffer = Vec::with_capacity(declared_size as usize);
        member.take(MAX_CHUNK_OUTPUT + 1).read_to_end(&mut buffer).map_err(|_| Error::ChunkDecompress)?;
        if buffer.len() as u64 > MAX_CHUNK_OUTPUT || buffer.len() as u64 != declared_size {
            return Err(Error::ChunkSize);
        }
        Ok(buffer)
    } else {
        Err(Error::ChunkFormat)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn archive_with_oversized_member() -> Vec<u8> {
        let mut zip = Cursor::new(Vec::new());
        {
            let mut writer = zip::ZipWriter::new(&mut zip);
            let options = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Stored);
            writer.start_file("member", options).unwrap();
            writer.write_all(b"x").unwrap();
            writer.finish().unwrap();
        }
        let mut archive = zip.into_inner();
        let central = archive.windows(4).position(|w| w == [0x50, 0x4b, 0x01, 0x02]).unwrap();
        archive[central + 24..central + 28].copy_from_slice(&((4 * 1024 * 1024 + 1) as u32).to_le_bytes());
        archive
    }

    #[tokio::test]
    async fn rejects_declared_oversized_zip_member_before_expansion() {
        use aes::cipher::{block_padding::Pkcs7, BlockEncrypt, BlockEncryptMut, KeyInit, KeyIvInit};
        type AesCbcEnc = cbc::Encryptor<aes::Aes256>;
        let plain = archive_with_oversized_member();
        let key = [7u8; 32];
        let iv = [9u8; 16];
        let mut padded = vec![0u8; plain.len() + 16];
        padded[..plain.len()].copy_from_slice(&plain);
        let ciphertext = AesCbcEnc::new(&key.into(), &iv.into())
            .encrypt_padded_mut::<Pkcs7>(&mut padded, plain.len()).unwrap().to_vec();
        let mut encrypted_iv = iv.into();
        aes::Aes256::new(&key.into()).encrypt_block(&mut encrypted_iv);
        let mut encrypted = encrypted_iv.to_vec();
        encrypted.extend(ciphertext);
        let error = decrypt_and_decompress(&mut encrypted, key).await.unwrap_err();
        assert!(matches!(error, Error::ChunkSize), "must reject the ZIP size, not merely fail decryption: {error}");
    }

    fn encrypt_chunk(plain: &[u8], key: [u8; 32]) -> Vec<u8> {
        use aes::cipher::{block_padding::Pkcs7, BlockEncrypt, BlockEncryptMut, KeyInit, KeyIvInit};
        let iv = [9u8; 16];
        let mut padded = vec![0; plain.len() + 16];
        padded[..plain.len()].copy_from_slice(plain);
        let ciphertext = cbc::Encryptor::<aes::Aes256>::new(&key.into(), &iv.into())
            .encrypt_padded_mut::<Pkcs7>(&mut padded, plain.len()).unwrap().to_vec();
        let mut encrypted_iv = iv.into();
        aes::Aes256::new(&key.into()).encrypt_block(&mut encrypted_iv);
        [encrypted_iv.as_slice(), &ciphertext].concat()
    }

    #[tokio::test]
    async fn decrypts_valve_zstd_chunk_with_real_aes_encrypted_iv() {
        let plain = b"synthetic Steam chunk payload, not user content";
        let compressed = zstd::stream::encode_all(Cursor::new(plain), 1).unwrap();
        let crc = crc32fast::hash(plain);
        let mut frame = b"VSZa".to_vec();
        frame.extend(crc.to_le_bytes());
        frame.extend(compressed);
        frame.extend(crc.to_le_bytes());
        frame.extend((plain.len() as u32).to_le_bytes());
        frame.extend([0; 4]);
        frame.extend(b"zsv");
        let key = [7; 32];
        let mut encrypted = encrypt_chunk(&frame, key);
        assert_eq!(decrypt_and_decompress(&mut encrypted, key).await.unwrap(), plain);
    }

    #[tokio::test]
    async fn decrypts_legacy_zip_and_lzma_and_rejects_wrong_key_or_format() {
        let plain = b"synthetic legacy Steam chunk";
        let key = [7; 32];
        let mut zip = zip::ZipWriter::new(Cursor::new(Vec::new()));
        zip.start_file("chunk", zip::write::SimpleFileOptions::default()).unwrap();
        zip.write_all(plain).unwrap();
        let mut encrypted = encrypt_chunk(&zip.finish().unwrap().into_inner(), key);
        assert_eq!(decrypt_and_decompress(&mut encrypted, key).await.unwrap(), plain);
        let mut lzma = Vec::new();
        lzma_rs::lzma_compress(&mut Cursor::new(plain), &mut lzma).unwrap();
        let crc = crc32fast::hash(plain);
        let mut frame = b"VZa".to_vec();
        frame.extend(crc.to_le_bytes());
        frame.extend(&lzma[..5]); // Raw LZMA properties; skip standalone size field.
        frame.extend(&lzma[13..]);
        frame.extend(crc.to_le_bytes());
        frame.extend((plain.len() as u32).to_le_bytes());
        frame.extend(b"zv");
        let mut encrypted = encrypt_chunk(&frame, key);
        assert_eq!(decrypt_and_decompress(&mut encrypted, key).await.unwrap(), plain);
        let mut encrypted = encrypt_chunk(b"unsupported compression marker", key);
        assert!(matches!(decrypt_and_decompress(&mut encrypted, key).await, Err(Error::ChunkFormat)));
        let mut encrypted = encrypt_chunk(&frame, key);
        assert!(matches!(decrypt_and_decompress(&mut encrypted, [0;32]).await, Err(Error::ChunkDecrypt)));
    }

    #[tokio::test]
    async fn rejects_too_small_encrypted_input() {
        assert!(decrypt_and_decompress(&mut [0u8; IV_LENGTH], [0; 32]).await.is_err());
    }
}
