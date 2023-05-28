package options

import (
	"errors"
	"fmt"
	"github.com/nacos-group/nacos-sdk-go/v2/clients"
	"github.com/nacos-group/nacos-sdk-go/v2/clients/config_client"
	"github.com/nacos-group/nacos-sdk-go/v2/common/constant"
	"github.com/nacos-group/nacos-sdk-go/v2/vo"
	"github.com/spf13/pflag"
	"net/url"
	"strconv"
)

type NacosOptions struct {
	ServerHttpUrls []string
	NamespaceId    string
	Username       string
	Password       string
	TimeoutMs      uint64
	LogDir         string
	CacheDir       string
}

func (o *NacosOptions) AddFlags(fs *pflag.FlagSet) {
	if o == nil {
		return
	}

	fs.StringSliceVar(&o.ServerHttpUrls, "nacos-server", []string{}, ""+
		"Per-resource etcd servers overrides, comma separated. The individual override "+
		"format: group/resource#servers, where servers are URLs, semicolon separated. "+
		"Note that this applies only to resources compiled into this server binary. ")
	fs.StringVar(&o.Username, "nacos-username", "", ""+
		"The media type to use to store objects in storage. "+
		"Some resources or storage backends may only support a specific media type and will ignore this setting. "+
		"Supported media types: [application/json, application/yaml, application/vnd.kubernetes.protobuf]")
	fs.StringVar(&o.Password, "nacos-password", "", ""+
		"The media type to use to store objects in storage. "+
		"Some resources or storage backends may only support a specific media type and will ignore this setting. "+
		"Supported media types: [application/json, application/yaml, application/vnd.kubernetes.protobuf]")
	fs.StringVar(&o.NamespaceId, "nacos-ns-id", "", ""+
		"The media type to use to store objects in storage. "+
		"Some resources or storage backends may only support a specific media type and will ignore this setting. "+
		"Supported media types: [application/json, application/yaml, application/vnd.kubernetes.protobuf]")
	fs.Uint64Var(&o.TimeoutMs, "nacos-timeout", 5000,
		"Number of workers spawned for DeleteCollection call. These are used to speed up namespace cleanup.")

	fs.StringVar(&o.LogDir, "nacos-log-dir", "/tmp/nacos/log", ""+
		"Enables the generic garbage collector. MUST be synced with the corresponding flag "+
		"of the kube-controller-manager.")
	fs.StringVar(&o.CacheDir, "nacos-cache-dir", "/tmp/nacos/cache", ""+
		"Enables the generic garbage collector. MUST be synced with the corresponding flag "+
		"of the kube-controller-manager.")
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

	serverConfigs := []constant.ServerConfig{}
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
		serverConfig := constant.ServerConfig{
			IpAddr:      serverUrl.Hostname(),
			ContextPath: serverUrl.Path,
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
