package options

import (
	"errors"
	"fmt"
	"github.com/alibaba/higress/api-server/pkg/utils"
	"github.com/nacos-group/nacos-sdk-go/v2/clients"
	"github.com/nacos-group/nacos-sdk-go/v2/clients/config_client"
	"github.com/nacos-group/nacos-sdk-go/v2/common/constant"
	"github.com/nacos-group/nacos-sdk-go/v2/vo"
	"github.com/spf13/pflag"
	"net/url"
	"os"
	"strconv"
	"strings"
)

const (
	Storage_File  = "file"
	Storage_Nacos = "nacos"
)

func CreateAuthOptions() *AuthOptions {
	return &AuthOptions{}
}

type AuthOptions struct {
	Enabled bool
}

func (o *AuthOptions) AddFlags(fs *pflag.FlagSet) {
	if o == nil {
		return
	}

	fs.BoolVar(&o.Enabled, "auth-enabled", false, "Whether to enable authentication and authorization for Higress API server.")
}

func (o *AuthOptions) Validate() []error {
	// Nothing to validate for now
	return []error{}
}

func CreateStorageOptions() *StorageOptions {
	return &StorageOptions{
		FileOptions:  &FileOptions{},
		NacosOptions: &NacosOptions{},
	}
}

type StorageOptions struct {
	Mode         string
	FileOptions  *FileOptions
	NacosOptions *NacosOptions
}

func (o *StorageOptions) AddFlags(fs *pflag.FlagSet) {
	if o == nil {
		return
	}

	fs.StringVar(&o.Mode, "storage", Storage_Nacos, "The storage mode. Valid options are: file, nacos.")

	o.FileOptions.AddFlags(fs)
	o.NacosOptions.AddFlags(fs)
}

func (o *StorageOptions) Validate() []error {
	errors := []error{}
	switch o.Mode {
	case Storage_File:
		errors = append(errors, o.FileOptions.Validate()...)
		break
	case Storage_Nacos:
		errors = append(errors, o.NacosOptions.Validate()...)
		break
	default:
		errors = append(errors, fmt.Errorf("invalid storage mode: %s", o.Mode))
	}
	return errors
}

type FileOptions struct {
	RootDir string
}

func (o *FileOptions) AddFlags(fs *pflag.FlagSet) {
	if o == nil {
		return
	}

	fs.StringVar(&o.RootDir, "file-root-dir", "./conf", "The root directory of the file backend.")
}

func (o *FileOptions) Validate() []error {
	if o == nil {
		return []error{
			fmt.Errorf("file configuration is not set"),
		}
	}

	errors := []error{}

	if o.RootDir == "" {
		errors = append(errors, fmt.Errorf("--file-root-dir must be set"))
	} else {
		fileInfo, err := os.Stat(o.RootDir)
		if err != nil {
			err := utils.EnsureDir(o.RootDir)
			if err != nil {
				errors = append(errors, fmt.Errorf("--file-root-dir doesn't exist and cannot be created: %s", err))
			}
		} else if !fileInfo.IsDir() {
			errors = append(errors, fmt.Errorf("--file-root-dir must be set to a directory path"))
		}
	}

	return errors
}

type NacosOptions struct {
	ServerHttpUrls    []string
	NamespaceId       string
	Username          string
	Password          string
	TimeoutMs         uint64
	LogDir            string
	CacheDir          string
	PrivateKeyFile    string
	EncryptionKeyFile string
	EncryptionKey     []byte
}

func (o *NacosOptions) AddFlags(fs *pflag.FlagSet) {
	if o == nil {
		return
	}

	fs.StringSliceVar(&o.ServerHttpUrls, "nacos-server", []string{}, ""+
		"URL of Nacos service. e.g.: http://localhost:8848/nacos")
	fs.StringVar(&o.Username, "nacos-username", "", ""+
		"The username used to access Nacos service. Leave it empty if authentication isn't enabled in Nacos.")
	fs.StringVar(&o.Password, "nacos-password", "", ""+
		"The password used to access Nacos service. Leave it empty if authentication isn't enabled in Nacos.")
	fs.StringVar(&o.NamespaceId, "nacos-ns-id", "higress-system", ""+
		"The namespace ID which Higress configurations are stored in. "+
		"It is recommended to give Higress a separate namespace for a better isolation.")
	fs.Uint64Var(&o.TimeoutMs, "nacos-timeout", 5000,
		"The timeout in milliseconds when trying to read data from Nacos server.")
	fs.StringVar(&o.EncryptionKeyFile, "nacos-encryption-key-file", "",
		"A file containing AES key data used for data encryption. The file length must be 16, 24 or 32 bytes. "+
			"If not set, data encryption will be disabled.")

	fs.StringVar(&o.LogDir, "nacos-log-dir", "/tmp/nacos/log", ""+
		"Directory to store Nacos logs.")
	fs.StringVar(&o.CacheDir, "nacos-cache-dir", "/tmp/nacos/cache", ""+
		"Directory to store Nacos cache data.")
}

func (o *NacosOptions) Validate() []error {
	if o == nil {
		return []error{
			fmt.Errorf("nacos configuration is not set"),
		}
	}

	errors := []error{}

	if o.ServerHttpUrls == nil || len(o.ServerHttpUrls) == 0 {
		errors = append(errors, fmt.Errorf("--nacos-server must be set"))
	} else {
		for _, server := range o.ServerHttpUrls {
			serverUrl, err := url.Parse(server)
			if err != nil {
				errors = append(errors, fmt.Errorf("invalid URL format: %s", server))
				continue
			}
			if serverUrl.Scheme != "http" {
				errors = append(errors, fmt.Errorf("only HTTP URLs are acceptable: %s", server))
				continue
			}
			rawPort := serverUrl.Port()
			if rawPort != "" {
				port, err := strconv.Atoi(rawPort)
				if err != nil || port < 1 || port > 65535 {
					errors = append(errors, fmt.Errorf("invalid port number: %s", server))
					continue
				}
			}
		}
	}

	if o.EncryptionKeyFile != "" {
		key, error := os.ReadFile(o.EncryptionKeyFile)
		if error != nil {
			errors = append(errors, fmt.Errorf("failed to read encryption key file: %s", error))
		} else {
			o.EncryptionKey = key
		}
		switch len(o.EncryptionKey) {
		case 16:
		case 24:
		case 32:
			// Good
			break
		default:
			errors = append(errors, fmt.Errorf("invalid encryption key length: %d", len(o.EncryptionKey)))
			break
		}
	}

	return errors
}

func (o *NacosOptions) CreateConfigClient() (config_client.IConfigClient, error) {
	if o == nil {
		return nil, errors.New("nacos configuration is not set")
	}

	clientConfig := constant.NewClientConfig(
		constant.WithNamespaceId(o.NamespaceId),
		constant.WithUsername(o.Username),
		constant.WithPassword(o.Password),
		constant.WithTimeoutMs(o.TimeoutMs),
		constant.WithLogDir(o.LogDir),
		constant.WithCacheDir(o.CacheDir),
		constant.WithLogLevel("info"),
		// Ignore snapshot so we can get the latest config right after making any change.
		constant.WithDisableUseSnapShot(true),
	)

	var serverConfigs []constant.ServerConfig
	for _, server := range o.ServerHttpUrls {
		serverUrl, err := url.Parse(server)
		if err != nil {
			continue
		}
		rawPort := serverUrl.Port()
		var port uint64
		if rawPort != "" {
			port, err = strconv.ParseUint(rawPort, 10, 0)
			if err != nil || port < 1 || port > 65535 {
				continue
			}
		} else {
			port = 80
		}
		path := serverUrl.Path
		if strings.HasSuffix(path, "/") {
			path = path[:len(path)-1]
		}
		serverConfig := constant.ServerConfig{
			IpAddr:      serverUrl.Hostname(),
			ContextPath: path,
			Port:        port,
			Scheme:      serverUrl.Scheme,
		}
		serverConfigs = append(serverConfigs, serverConfig)
	}
	return clients.NewConfigClient(
		vo.NacosClientParam{
			ClientConfig:  clientConfig,
			ServerConfigs: serverConfigs,
		},
	)
}
