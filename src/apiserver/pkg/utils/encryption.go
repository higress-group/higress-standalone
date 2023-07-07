package utils

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
)

func AesEncrypt(data, key []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}

	blockSize := block.BlockSize()
	data = pkcs5Padding(data, blockSize)

	blockMode := cipher.NewCBCEncrypter(block, key[:blockSize])
	crypted := make([]byte, len(data))

	blockMode.CryptBlocks(crypted, data)
	return crypted, nil
}

func AesDecrypt(encryptedData, key []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}

	blockSize := block.BlockSize()
	blockMode := cipher.NewCBCDecrypter(block, key[:blockSize])
	origData := make([]byte, len(encryptedData))

	blockMode.CryptBlocks(origData, encryptedData)
	origData = pkcs5Unpadding(origData)
	return origData, nil
}

func RsaEncrypt(data, label []byte, publicKey *rsa.PublicKey) ([]byte, error) {
	encryptedData, err := rsa.EncryptOAEP(sha256.New(), rand.Reader, publicKey, data, label)
	if err != nil {
		return nil, err
	}
	return encryptedData, nil
}

func RsaDecrypt(encryptedData, label []byte, privateKey *rsa.PrivateKey) ([]byte, error) {
	decryptedData, err := rsa.DecryptOAEP(sha256.New(), rand.Reader, privateKey, encryptedData, label)
	if err != nil {
		return nil, err
	}
	return decryptedData, nil
}

func pkcs5Padding(data []byte, blockSize int) []byte {
	padding := blockSize - len(data)%blockSize
	paddedData := bytes.Repeat([]byte{byte(padding)}, padding)
	return append(data, paddedData...)
}

func pkcs5Unpadding(data []byte) []byte {
	length := len(data)
	paddingLength := int(data[length-1])
	return data[:(length - paddingLength)]
}
