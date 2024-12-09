module github.com/docker-library/meta-scripts

// ideally this would be the single source of truth for this entire repository, but riscv64 means this bleeds into .go-env.sh too -- if changing this, see that file too
go 1.21

require (
	cuelabs.dev/go/oci/ociregistry v0.0.0-20240214163758-5ebe80b0a9a6
	github.com/docker-library/bashbrew v0.1.11
	github.com/opencontainers/go-digest v1.0.0
	github.com/opencontainers/image-spec v1.1.0
	golang.org/x/time v0.5.0
)

require (
	github.com/Microsoft/hcsshim v0.9.10 // indirect
	github.com/containerd/containerd v1.6.26 // indirect
	github.com/containerd/log v0.1.0 // indirect
	github.com/golang/protobuf v1.5.3 // indirect
	github.com/sirupsen/logrus v1.9.3 // indirect
	golang.org/x/sys v0.13.0 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20230711160842-782d3b101e98 // indirect
	google.golang.org/grpc v1.58.3 // indirect
	google.golang.org/protobuf v1.31.0 // indirect
)

// https://github.com/cue-labs/oci/pull/29
replace cuelabs.dev/go/oci/ociregistry => github.com/khulnasoft/cuelabs-oci/ociregistry v0.0.0-20240214163758-5ebe80b0a9a6
