# TUFF 7.0.0 inference investigation

No inference kernel or execution policy change qualified for this release. The engine, CLI inference runner and model packs retain the 6.1.0 paths. Shared version reporting and routed serving change the surrounding interfaces.

## Shape trials

The inherited investigation used the 16 GB M2 MacBook Air, 31 alternating pairs per shape and an independent CPU reference. Production int4 GEMV reached 80 to 88 GB/s on medium and large projections. A four-row layout won 30 of 31 Flash Next 512 × 2560 KV comparisons, about 10%, and 29 of 31 E2B KV comparisons, about 7%. An eight-wide variant gained 3 to 9% on some narrow shapes. The benefit did not carry across shapes.

Five identical E2B end-to-end runs fell from 50.3 to 38.4 tok/s. Thermal throttling is a possible explanation on this fanless host, not a measured cause. Gains below that variation cannot qualify a general dispatch change. None of these variants ships.

## Flash Next

Inherited CPU samples show substantial `pread` and GPU synchronization waits. Two identical decode runs measured 1.17 and 2.21 tok/s; one 48-token run spent 46 seconds in system time. These observations support investigating the I/O and synchronization path but do not establish an additive latency breakdown.

N-gram PLE accounted for about 80 of roughly 14,000 main-thread samples in a 1,082-token prefill, about 0.6%. The existing lookup keeps exact hashing, context and dilated convolution history. A second batching implementation was not justified by this sample share and was not shipped.

## Qwen GDN prefill

Source inspection confirms batched projections and causal convolution, followed by the delta-rule token loop inside each state-row kernel. State stays in FP32 registers across the chunk and is written back at its end. A block-parallel recurrence would change floating-point ordering and needs independent state, output and continuation comparisons before deployment. It was not implemented or performance-qualified here. The existing sequential recurrence, convolution carry, reset and chunk-boundary paths remain covered by the canonical numerical tests.

## Gemma 26B

The inherited head command buffer averaged 12.8 ms per token, compared with 4.6 ms, about 90 GB/s, for the same GEMV in a steady-state shape benchmark. GPU clock ramp-down between synchronized layers is an untested hypothesis. There is no GPU clock measurement or qualified scheduling change.

## Qualification

Repeated alternating 6.1.0 and candidate CLI comparisons are recorded in [release validation](RELEASE_7.0.0_VALIDATION.md). They retain every repetition, output identity and host observations. Filesystem caches, swap and host activity remain uncontrolled. Smoke checks do not establish model quality or optimal speed. Other chips and larger-memory execution regimes require separate qualification.
