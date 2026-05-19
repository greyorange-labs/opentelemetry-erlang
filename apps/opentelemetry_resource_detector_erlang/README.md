# opentelemetry_resource_detector_erlang

BEAM-aware [OpenTelemetry Resource](https://opentelemetry.io/docs/concepts/resources/) detectors for Erlang/OTP, providing parity with the Java OTel agent's auto-instrumented resource attributes.

## Overview

This OTP application provides three resource detectors and a convenience facade that merges all three:

| Module | Attributes |
|--------|------------|
| `beam_runtime_detector` | `process.pid`, `process.runtime.name`, `process.runtime.version`, `process.runtime.description` |
| `host_detector` | `host.name`, `host.arch`, `host.id`, `os.type`, `os.description` |
| `service_detector` | `service.name`, `service.namespace`, `service.version`, `deployment.environment` |
| `opentelemetry_resource_detector_erlang` | All of the above (merged) |

## Usage

### Facade (recommended)

```erlang
Resource = opentelemetry_resource_detector_erlang:detect(),
AttrMap  = otel_attributes:map(otel_resource:attributes(Resource)).
```

### Individual detectors

```erlang
R1 = beam_runtime_detector:detect(),
R2 = host_detector:detect(),
R3 = service_detector:detect().
```

### Registering with the OTel SDK

Pass the detector to the `opentelemetry` application's `resource_detectors` config:

```erlang
%% sys.config
{opentelemetry, [
    {resource_detectors, [opentelemetry_resource_detector_erlang]}
]}
```

This requires the module to implement `otel_resource_detector:get_resource/1`. The current version exposes a direct `detect/0` API; wrapping it for the SDK behaviour is a planned enhancement.

## Environment variables

`service_detector` reads the following OS environment variables at detection time:

| Variable | Attribute |
|----------|-----------|
| `OTEL_SERVICE_NAME` | `service.name` |
| `OTEL_SERVICE_NAMESPACE` | `service.namespace` |
| `TENANT_ID` | `deployment.environment` |

Attributes whose source variable is unset or empty are omitted from the resource.

## host.id resolution

`host_detector` reads `/etc/machine-id` when available (Linux). On macOS or containers without that file, it falls back to an MD5 hash of the resolved hostname, encoded as a hex string.

## Dependencies

- `kernel`, `stdlib` (OTP standard)
- `opentelemetry_api` (from this repo)
- `crypto` (used by `host_detector` for the MD5 fallback)

## Running tests

```bash
cd <repo-root>
rebar3 ct --suite=apps/opentelemetry_resource_detector_erlang/test/beam_runtime_detector_SUITE
rebar3 ct --suite=apps/opentelemetry_resource_detector_erlang/test/host_detector_SUITE
rebar3 ct --suite=apps/opentelemetry_resource_detector_erlang/test/service_detector_SUITE
rebar3 ct --suite=apps/opentelemetry_resource_detector_erlang/test/opentelemetry_resource_detector_erlang_SUITE
```

## Status

Experimental. Part of the GreyOrange `opentelemetry-erlang` fork POC
([spec](../../../butler_server-develop/plans/otel-erlang-fork-poc-spec.md)).
Candidate for upstream contribution as a standalone hex package.

Pinned upstream baseline: `8fa66fdb448f16bc3d22af93d6c7ed3ea4b647b6` (set in fork main README).

## License

Apache-2.0 — see the top-level [LICENSE](../../LICENSE) file.
