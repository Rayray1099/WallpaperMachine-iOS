use std::io::{Cursor, Read};
use zip::ZipArchive;

use crate::{
    crypto::aes256::{self, IV_LENGTH},
    utils::lzma,
    Error,
};

pub async fn decrypt_and_decompress(data: &mut [u8], key: [u8; 32]) -> Result<Vec<u8>, Error> {
    if data.len() <= IV_LENGTH {
        return Err(Error::Eof("data is too small".to_string()));
    }

    let decrypted = aes256::decrypt_cbc_with_iv_extraction(data, key)?;
    if lzma::is_vz(&decrypted) {
        Ok(lzma::decompress(&decrypted).await?)
    } else {
        let cursor = Cursor::new(decrypted);
        let mut archive = ZipArchive::new(cursor)?;
        let mut member = archive.by_index(0)?;
        const MAX_CHUNK_OUTPUT: u64 = 4 * 1024 * 1024;
        if member.size() > MAX_CHUNK_OUTPUT {
            return Err(Error::Unexpected("decompressed chunk exceeds 4 MiB".into()));
        }
        let declared_size = member.size();
        let mut buffer = Vec::with_capacity(declared_size as usize);
        member.take(MAX_CHUNK_OUTPUT + 1).read_to_end(&mut buffer)?;
        if buffer.len() as u64 > MAX_CHUNK_OUTPUT || buffer.len() as u64 != declared_size {
            return Err(Error::Unexpected("invalid decompressed chunk length".into()));
        }
        Ok(buffer)
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
        assert!(error.to_string().contains("4 MiB"), "must reject the ZIP size, not merely fail decryption: {error}");
    }

    #[tokio::test]
    async fn rejects_too_small_encrypted_input() {
        assert!(decrypt_and_decompress(&mut [0u8; IV_LENGTH], [0; 32]).await.is_err());
    }
}
