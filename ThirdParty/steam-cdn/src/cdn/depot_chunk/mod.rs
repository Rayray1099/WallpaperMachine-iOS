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
