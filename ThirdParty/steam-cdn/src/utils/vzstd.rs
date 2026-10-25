//! Steam's VSZa wrapper: 8-byte header, a Zstd frame, 15-byte footer.
//! Public framing reference: SteamKit2/Util/VZstdUtil.cs; no reference code copied.
use std::io::{Cursor, Read};
use crate::Error;

const MAX_OUTPUT: u32 = 4 * 1024 * 1024;
const MAX_WINDOW_LOG: u32 = 26; // 64 MiB, independent of untrusted frame window.

pub fn decompress(data: &[u8]) -> Result<Vec<u8>, Error> {
    if data.len() < 23 || !data.starts_with(b"VSZa") || !data.ends_with(b"zsv") {
        return Err(Error::ChunkDecompress);
    }
    let footer = data.len() - 15;
    let header_crc = u32::from_le_bytes(data[4..8].try_into().unwrap());
    let footer_crc = u32::from_le_bytes(data[footer..footer + 4].try_into().unwrap());
    let size = u32::from_le_bytes(data[footer + 4..footer + 8].try_into().unwrap());
    if size > MAX_OUTPUT { return Err(Error::ChunkSize); }
    if header_crc != footer_crc { return Err(Error::ChunkChecksum); }
    let mut decoder = zstd::stream::read::Decoder::new(Cursor::new(&data[8..footer]))
        .map_err(|_| Error::ChunkDecompress)?;
    decoder.window_log_max(MAX_WINDOW_LOG).map_err(|_| Error::ChunkDecompress)?;
    let mut output = Vec::with_capacity(size as usize);
    decoder.take(size as u64 + 1).read_to_end(&mut output)
        .map_err(|_| Error::ChunkDecompress)?;
    if output.len() != size as usize { return Err(Error::ChunkSize); }
    if crc32fast::hash(&output) != footer_crc { return Err(Error::ChunkChecksum); }
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn frame(plain: &[u8]) -> Vec<u8> {
        let crc = crc32fast::hash(plain);
        let mut data = b"VSZa".to_vec();
        data.extend(crc.to_le_bytes());
        data.extend(zstd::stream::encode_all(Cursor::new(plain), 1).unwrap());
        data.extend(crc.to_le_bytes());
        data.extend((plain.len() as u32).to_le_bytes());
        data.extend([0; 4]);
        data.extend(b"zsv");
        data
    }
    #[test]
    fn rejects_bad_framing_declared_size_and_crc() {
        let valid = frame(b"synthetic");
        assert_eq!(decompress(&valid).unwrap(), b"synthetic");
        for len in 0..23 { assert!(decompress(&valid[..len]).is_err()); }
        let footer = valid.len() - 15;
        let mut data = valid.clone();
        data[footer + 4..footer + 8].copy_from_slice(&(MAX_OUTPUT + 1).to_le_bytes());
        assert!(matches!(decompress(&data), Err(Error::ChunkSize)));
        let mut data = valid.clone(); data[4] ^= 1;
        assert!(matches!(decompress(&data), Err(Error::ChunkChecksum)));
        let mut data = valid.clone(); data[4] ^= 1; data[footer] ^= 1;
        assert!(matches!(decompress(&data), Err(Error::ChunkChecksum)));
        let mut data = valid.clone(); data[footer + 4] += 1;
        assert!(matches!(decompress(&data), Err(Error::ChunkSize)));
        let mut data = valid; *data.last_mut().unwrap() = 0;
        assert!(decompress(&data).is_err());
    }
    #[test]
    fn rejects_oversized_window_before_allocation() {
        // Valid Zstd magic + non-single-segment header, 128 MiB window, empty block.
        let mut data = frame(b"");
        let footer = data.len() - 15;
        data.splice(8..footer, [0x28,0xb5,0x2f,0xfd, 0x00, 0x88, 0x01,0x00,0x00]);
        assert!(matches!(decompress(&data), Err(Error::ChunkDecompress)));
    }
}
