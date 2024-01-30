package utils

import (
	"os"
	"strconv"
)

func GetStringFromEnv(key, defaultValue string) string {
	if len(key) == 0 {
		return defaultValue
	}
	value := os.Getenv(key)
	if len(value) != 0 {
		return value
	}
	return defaultValue
}

func GetIntFromEnv(key string, defaultValue int) int {
	strValue := GetStringFromEnv(key, "")
	if len(strValue) == 0 {
		return defaultValue
	}
	if value, err := strconv.Atoi(strValue); err != nil {
		return defaultValue
	} else {
		return value
	}
}

func GetBoolFromEnv(key string, defaultValue bool) bool {
	strValue := GetStringFromEnv(key, "")
	if len(strValue) == 0 {
		return defaultValue
	}
	if value, err := strconv.ParseBool(strValue); err != nil {
		return defaultValue
	} else {
		return value
	}
}
