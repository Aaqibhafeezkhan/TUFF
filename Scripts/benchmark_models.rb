#!/usr/bin/env ruby
# frozen_string_literal: true

# Shared launch-model table for the benchmark scripts. Each entry pins the
# chat and sampling flags plus explicit 16 GB release-check runtime settings.
# Context stays at 4K for comparable smoke checks, rather than Auto context.

BENCHMARK_MODELS = {
  "gemma4-e2b" => {
    path: "scratch/gemma4-e2b.gturbo",
    chat: %w[--thinking off],
    sampling: %w[--temperature 1.0 --top-k 64 --top-p 0.95],
    runtime: %w[--expert-cache-slots 16 --prefill on --prefill-chunk-tokens 256 --rdadvise off]
  },
  "gemma4-e4b" => {
    path: "scratch/gemma4-e4b.gturbo",
    chat: %w[--thinking off],
    sampling: %w[--temperature 1.0 --top-k 64 --top-p 0.95],
    runtime: %w[--expert-cache-slots 16 --prefill on --prefill-chunk-tokens 256 --rdadvise off]
  },
  "gemma4-12b-qat" => {
    path: "scratch/gemma4-12b-qat.gturbo",
    chat: %w[--thinking off],
    sampling: %w[--temperature 1.0 --top-k 64 --top-p 0.95],
    runtime: %w[--expert-cache-slots 16 --prefill on --prefill-chunk-tokens 256 --rdadvise off]
  },
  "gemma4" => {
    path: "scratch/gemma4.gturbo",
    chat: %w[--thinking off],
    sampling: %w[--temperature 0.2 --top-k 64 --top-p 0.95],
    runtime: %w[--expert-cache-slots 16 --prefill on --prefill-chunk-tokens 512 --rdadvise off]
  },
  "qwen36" => {
    path: "scratch/qwen36.gturbo",
    chat: %w[--thinking off],
    sampling: %w[--temperature 0.2 --top-k 64 --top-p 0.95],
    runtime: %w[--expert-cache-slots 16 --prefill on --prefill-chunk-tokens 2048 --rdadvise off]
  },
  "gpt-oss-20b" => {
    path: "scratch/gpt-oss-20b.gturbo",
    chat: %w[--reasoning low],
    sampling: %w[--temperature 1.0 --top-k 0 --top-p 1.0],
    runtime: %w[--expert-cache-slots 16 --prefill on --prefill-chunk-tokens 512 --rdadvise off]
  },
  "gpt-oss-120b" => {
    path: "scratch/gpt-oss-120b.gturbo",
    chat: %w[--reasoning low],
    sampling: %w[--temperature 1.0 --top-k 0 --top-p 1.0],
    runtime: %w[--expert-cache-slots 4 --prefill off --prefill-chunk-tokens 2048 --rdadvise bounded]
  },
  "minimax-m2.7" => {
    path: "scratch/minimax-m2.7.gturbo",
    chat: [],
    sampling: %w[--temperature 1.0 --top-k 40 --top-p 0.95],
    runtime: %w[--expert-cache-slots 16 --prefill on --prefill-chunk-tokens 2048 --rdadvise bounded]
  },
  # 16 slots is the 9.0 default; larger caches must demonstrate a safe benefit.
  "qwen38-flash-next" => {
    path: "scratch/qwen38-flash-next.gturbo",
    chat: [],
    sampling: %w[--temperature 1.0 --top-k 20 --top-p 0.95],
    runtime: %w[--expert-cache-slots 16 --prefill on --prefill-chunk-tokens 2048 --rdadvise bounded]
  },
  "ornith-9b" => {
    path: "scratch/ornith-9b.gturbo", chat: %w[--thinking off],
    sampling: %w[--temperature 0.7 --top-k 20 --top-p 0.8],
    runtime: %w[--expert-cache-slots 16 --prefill on --prefill-chunk-tokens 256 --rdadvise off]
  },
  "ornith-35b" => {
    path: "scratch/ornith-35b.gturbo", chat: %w[--thinking off],
    sampling: %w[--temperature 0.7 --top-k 20 --top-p 0.8],
    runtime: %w[--expert-cache-slots 16 --prefill on --prefill-chunk-tokens 128 --rdadvise off]
  },
  "qwen38-27b" => {
    path: "scratch/qwen38-27b.gturbo", chat: %w[--thinking off],
    sampling: %w[--temperature 0.7 --top-k 20 --top-p 0.8],
    runtime: %w[--expert-cache-slots 16 --prefill on --prefill-chunk-tokens 128 --rdadvise off]
  },
  "ornith-397b" => {
    path: "scratch/ornith-397b.gturbo", chat: %w[--thinking off],
    sampling: %w[--temperature 0.7 --top-k 20 --top-p 0.8],
    runtime: %w[--expert-cache-slots 10 --prefill off --prefill-chunk-tokens 32 --rdadvise off]
  }
}.freeze

BENCHMARK_MODEL_LABELS = {
  "gemma4-e2b" => "Gemma 4 E2B IT",
  "gemma4-e4b" => "Gemma 4 E4B IT",
  "gemma4-12b-qat" => "Gemma 4 12B IT QAT",
  "gemma4" => "Gemma 4 26B-A4B IT",
  "qwen36" => "Qwen3.6 35B-A3B",
  "gpt-oss-20b" => "GPT-OSS 20B",
  "gpt-oss-120b" => "GPT-OSS 120B",
  "minimax-m2.7" => "MiniMax M2.7 4-bit",
  "qwen38-flash-next" => "Qwen3.8 Flash Next 4-bit",
  "ornith-9b" => "Ornith 1.5 9B Q4",
  "ornith-35b" => "Ornith 1.5 35B-A3B Q4",
  "qwen38-27b" => "Qwen3.8 27B Q4",
  "ornith-397b" => "Ornith 1.5 397B Q4"
}.freeze
