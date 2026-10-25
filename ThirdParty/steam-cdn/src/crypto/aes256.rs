use aes::{
    cipher::{
        block_padding::{Pkcs7, UnpadError},
        generic_array::GenericArray,
        BlockDecrypt, BlockDecryptMut, KeyInit, KeyIvInit,
    },
    Aes256, Aes256Dec,
};

pub const IV_LENGTH: usize = 16;

pub fn decrypt_cbc_with_iv_extraction(
    data: &mut [u8],
    key: [u8; 32],
) -> Result<Vec<u8>, UnpadError> {
    if data.len() < IV_LENGTH * 2 || data.len() % IV_LENGTH != 0 {
        return Err(UnpadError);
    }
    let mut iv = [0u8; IV_LENGTH];
    iv.copy_from_slice(&data[..IV_LENGTH]);
    Aes256Dec::new(GenericArray::from_slice(&key))
        .decrypt_block(GenericArray::from_mut_slice(&mut iv[..]));

    Ok(cbc::Decryptor::<Aes256>::new(
        GenericArray::from_slice(&key),
        GenericArray::from_slice(&iv),
    )
    .decrypt_padded_mut::<Pkcs7>(&mut data[IV_LENGTH..])?
    .to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_short_and_unaligned_ciphertext_without_panicking() {
        for length in 0..96 {
            if length >= 32 && length % 16 == 0 { continue; }
            assert!(decrypt_cbc_with_iv_extraction(&mut vec![0; length], [0;32]).is_err(), "length {length}");
        }
    }
}
