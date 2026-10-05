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
  def contributor_workflow(dir)
    File.join(dir, '.github/workflows/contributor-checks.yml')
  end
  def test_contributor_checks_do_not_run_on_pushes
    fixture do |dir|
      path = contributor_workflow(dir)
      File.write(path, File.read(path).sub("on:\n", "on:\n  push:\n    branches: [main]\n"))
      _, err, status = check(dir)
      refute status.success?
      assert_includes err, "runs repository code on 'push'"
    end
  end
  def test_a_separate_push_workflow_cannot_run_the_same_checks
    fixture do |dir|
      File.write(File.join(dir, '.github/workflows/main.yml'), <<~YAML)
        on:
          push:
            branches: [main]
        permissions:
          contents: read
        jobs:
          test:
            runs-on: macos-26
            steps:
              - uses: actions/checkout@v4
              - run: Scripts/check.sh
      YAML
      _, err, status = check(dir)
      refute status.success?
      assert_includes err, "runs repository code on 'push'"
    end
  end
  def test_jobs_are_gated_on_the_pull_request_author_not_the_actor
    fixture do |dir|
      path = contributor_workflow(dir)
      File.write(path, File.read(path).gsub('github.event.pull_request.user.login', 'github.actor'))
      _, err, status = check(dir)
      refute status.success?
      assert_includes err, 'decides on the actor'
      assert_includes err, 'has no pull request author condition'
    end
  end
  def test_every_contributor_job_has_an_author_condition
    fixture do |dir|
      path = contributor_workflow(dir)
      source = File.read(path)
      gate = "    if: github.event_name == 'workflow_dispatch' || github.event.pull_request.user.login != github.repository_owner\n"
      assert_includes source, gate
      File.write(path, source.sub(gate, ''))
      _, err, status = check(dir)
      refute status.success?
      assert_includes err, "job 'repository' has no pull request author condition"
    end
  end
  def test_test_workflows_cannot_read_secrets
    fixture do |dir|
      path = contributor_workflow(dir)
      File.write(path, File.read(path).sub('${{ github.token }}', '${{ secrets.SIGNING_KEY }}'))
      _, err, status = check(dir)
      refute status.success?
      assert_includes err, 'must not read secrets'
    end
  end
end
