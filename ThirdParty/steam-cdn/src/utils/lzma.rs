use lzma_rs::decompress::raw::{LzmaDecoder, LzmaParams, LzmaProperties};
use std::io::{Cursor, SeekFrom};
use tokio::{
    io::{AsyncReadExt, AsyncSeekExt},
    task,
};

use crate::Error;

const VZ_HEADER: u16 = 0x5A56;
const VZ_FOOTER: u16 = 0x767A;
const VZ_VERSION: char = 'a';
const MAX_LZMA_OUTPUT: u32 = 4 * 1024 * 1024;
const MAX_LZMA_DICTIONARY: u32 = 64 * 1024 * 1024;
const VZ_HEADER_LENGTH: usize = 7;
const VZ_FOOTER_LENGTH: usize = 10;

pub fn is_vz(data: &[u8]) -> bool {
    data.len() >= 2 && u16::from_le_bytes([data[0], data[1]]) == VZ_HEADER
}

pub async fn decompress(data: &[u8]) -> Result<Vec<u8>, Error> {
    let mut cursor = Cursor::new(data);
    if cursor.read_u16_le().await? != VZ_HEADER {
        return Err(Error::Eof("expecting VZ header".to_string()));
    }

    if cursor.read_u8().await? != VZ_VERSION as u8 {
        return Err(Error::Eof("expecting VZ header".to_string()));
    }

    if cursor.get_ref().len() < VZ_HEADER_LENGTH + VZ_FOOTER_LENGTH {
        return Err(Error::Eof("truncated VZ stream".into()));
    }
    let mut properties = [0u8; 5];
    cursor.seek(SeekFrom::Current(4)).await?; // skip crc32
    cursor.read_exact(&mut properties).await?;

    let buffer_size = cursor.get_ref().len() - properties.len() - VZ_HEADER_LENGTH - VZ_FOOTER_LENGTH;
    let mut buffer = vec![0u8; buffer_size];
    cursor.read_exact(&mut buffer).await?;

    let decompressed_crc32 = cursor.read_u32_le().await?;
    let decompressed_size = cursor.read_u32_le().await?;

    if decompressed_size > MAX_LZMA_OUTPUT {
        return Err(Error::Decompress("declared LZMA output exceeds 4 MiB".into()));
    }
    let declared_dict = u32::from_le_bytes([properties[1], properties[2], properties[3], properties[4]]);
    if declared_dict > MAX_LZMA_DICTIONARY {
        return Err(Error::Decompress("LZMA dictionary exceeds 64 MiB".into()));
    }
    if cursor.read_u16_le().await? != VZ_FOOTER {
        return Err(Error::Eof("expecting VZ at end of stream".to_string()));
    }

    let decompressed_data = task::spawn_blocking(move || -> Result<Vec<u8>, Error> {
        let mut decompressed = Vec::with_capacity(decompressed_size as usize);

        let lc = (properties[0] % 9) as u32;
        let remainder = (properties[0] / 9) as u32;
        let lp = remainder % 5;
        let pb = remainder / 5;

        let mut dict_size = 0u32;

        for i in 0..4 {
            dict_size += (properties[1 + i] as u32) << (i * 8);
        }

        LzmaDecoder::new(
            LzmaParams::new(
                LzmaProperties { lc, lp, pb },
                dict_size,
                Some(decompressed_size as u64),
            ),
            None,
        )?
        .decompress(&mut Cursor::new(buffer), &mut decompressed)?;

        Ok(decompressed)
    })
    .await??;

    if decompressed_data.len() != decompressed_size as usize {
        return Err(Error::Decompress("LZMA output size mismatch".into()));
    }
    if decompressed_crc32 != crc32fast::hash(&decompressed_data) {
        return Err(Error::Decompress("crc32 mismatch".to_string()));
    }

    Ok(decompressed_data)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn rejects_truncated_vz_header_without_panicking() {
        let truncated = [0x56, 0x5a, b'a'];
        assert!(decompress(&truncated).await.is_err());
    }

    #[tokio::test]
    async fn rejects_declared_output_above_limit_before_decoder() {
        let mut data = vec![0u8; VZ_HEADER_LENGTH + 5 + VZ_FOOTER_LENGTH];
        data[0..2].copy_from_slice(&VZ_HEADER.to_le_bytes());
        data[2] = VZ_VERSION as u8;
        data[7] = 0x5d;
        data[12..16].copy_from_slice(&0u32.to_le_bytes());
        data[16..20].copy_from_slice(&0x0400_0001u32.to_le_bytes());
        data[20..22].copy_from_slice(&VZ_FOOTER.to_le_bytes());
        assert!(decompress(&data).await.is_err());
    }

    #[tokio::test]
    async fn rejects_declared_dictionary_above_limit_before_decoder() {
        let mut data = vec![0u8; VZ_HEADER_LENGTH + 5 + VZ_FOOTER_LENGTH];
        data[0..2].copy_from_slice(&VZ_HEADER.to_le_bytes());
        data[2] = VZ_VERSION as u8;
        data[7] = 0x5d;
        data[12..16].copy_from_slice(&(MAX_LZMA_DICTIONARY + 1).to_le_bytes());
        data[16..20].copy_from_slice(&0u32.to_le_bytes());
        data[20..22].copy_from_slice(&VZ_FOOTER.to_le_bytes());
        assert!(decompress(&data).await.is_err());
    }
}
