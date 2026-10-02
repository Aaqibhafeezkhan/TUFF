#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'

class GitHubConfigTests < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  def fixture
    Dir.mktmpdir('tuff-github-config') do |dir|
      FileUtils.cp_r(File.join(ROOT, '.github'), dir)
      yield dir
    end
  end
  def check(dir)
    Open3.capture3({'TUFF_CHECK_ROOT' => dir}, RbConfig.ruby, File.join(ROOT, 'Scripts/check_github_config.rb'))
  end
  def test_current_configuration
    fixture { |dir| out, err, status = check(dir); assert status.success?, out + err }
  end
  def test_unknown_area_is_rejected
    fixture do |dir|
      path = File.join(dir, '.github/ISSUE_TEMPLATE/bug.yml')
      File.write(path, File.read(path).sub('Chat and generation', 'Unmapped area'))
      _, err, status = check(dir)
      refute status.success?
      assert_includes err, 'has no route'
    end
  end
  def test_duplicate_field_is_rejected
    fixture do |dir|
      path = File.join(dir, '.github/ISSUE_TEMPLATE/bug.yml')
      File.write(path, File.read(path).sub('id: hardware', 'id: version'))
      _, err, status = check(dir)
      refute status.success?
      assert_includes err, 'duplicate field'
    end
  end
  def test_privileged_checkout_is_rejected_even_without_an_explicit_ref
    fixture do |dir|
      File.write(File.join(dir, '.github/workflows/unsafe.yml'), <<~YAML)
        on: pull_request_target
        permissions:
          contents: read
        jobs:
          unsafe:
            runs-on: ubuntu-latest
            steps:
              - uses: actions/checkout@v4
      YAML
      _, err, status = check(dir)
      refute status.success?
      assert_includes err, 'untrusted pull request code'
    end
  end
end
