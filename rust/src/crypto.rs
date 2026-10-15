//! The few crypto primitives the robot and Xiaomi cloud need.
use aes::{Aes128, Aes256};
use cbc::cipher::block_padding::{NoPadding, Pkcs7};
use cbc::cipher::{BlockModeDecrypt, BlockModeEncrypt, KeyIvInit};
use md5::{Digest as _, Md5};
use sha1::Sha1;
use sha2::Sha256;
use std::io::Read;

pub fn md5(data: &[u8]) -> [u8; 16] {
    Md5::digest(data).into()
}
pub fn sha1(data: &[u8]) -> Vec<u8> {
    Sha1::digest(data).to_vec()
}
pub fn sha256(data: &[u8]) -> Vec<u8> {
    Sha256::digest(data).to_vec()
}

pub fn aes128_encrypt(data: &[u8], key: &[u8; 16], iv: &[u8; 16]) -> Vec<u8> {
    cbc::Encryptor::<Aes128>::new(key.into(), iv.into()).encrypt_padded_vec::<Pkcs7>(data)
}

pub fn aes128_decrypt(data: &[u8], key: &[u8; 16], iv: &[u8; 16]) -> Result<Vec<u8>, String> {
    cbc::Decryptor::<Aes128>::new(key.into(), iv.into())
        .decrypt_padded_vec::<Pkcs7>(data)
        .map_err(|_| "bad padding".to_string())
}

/// AES-256-CBC without padding (map files).
pub fn aes256_decrypt_raw(data: &[u8], key: &[u8; 32], iv: &[u8; 16]) -> Result<Vec<u8>, String> {
    cbc::Decryptor::<Aes256>::new(key.into(), iv.into())
        .decrypt_padded_vec::<NoPadding>(data)
        .map_err(|_| "map data isn't a whole number of AES blocks".to_string())
}

/// RC4 that drops the first 1024 keystream bytes (Xiaomi cloud's "RC4-drop1024").
pub fn rc4_drop1024(key: &[u8], data: &[u8]) -> Vec<u8> {
    let mut s: Vec<u8> = (0..=255).collect();
    let mut j = 0usize;
    for i in 0..256 {
        j = (j + s[i] as usize + key[i % key.len()] as usize) & 0xFF;
        s.swap(i, j);
    }
    let (mut i, mut j) = (0usize, 0usize);
    let mut next = move || {
        i = (i + 1) & 0xFF;
        j = (j + s[i] as usize) & 0xFF;
        s.swap(i, j);
        s[(s[i] as usize + s[j] as usize) & 0xFF]
    };
    for _ in 0..1024 {
        next();
    }
    data.iter().map(|b| b ^ next()).collect()
}

/// Inflates a zlib stream (2-byte header + deflate). Trailing bytes after the stream are ignored.
pub fn zlib_decompress(data: &[u8]) -> Result<Vec<u8>, String> {
    if data.len() <= 2 {
        return Err("the map data is too short".into());
    }
    let mut out = Vec::new();
    flate2::read::DeflateDecoder::new(&data[2..])
        .read_to_end(&mut out)
        .map_err(|e| format!("couldn't decompress the map: {e}"))?;
    Ok(out)
}

pub fn random_bytes<const N: usize>() -> [u8; N] {
    let mut bytes = [0u8; N];
    for b in bytes.iter_mut() {
        *b = rand::random();
    }
    bytes
}
