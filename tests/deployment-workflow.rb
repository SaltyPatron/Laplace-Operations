require 'yaml'
require 'minitest/autorun'
class DeploymentWorkflow < Minitest::Test
  def setup
    @jobs = YAML.load_file(File.expand_path('../.github/workflows/laplace.yml', __dir__)).fetch('jobs')
  end
  def test_acceptance_changes_run_checks_without_deploying_native_runtime
    runtime=YAML.load_file(File.expand_path('../.github/workflows/laplace.yml', __dir__))
    trigger=runtime.fetch('on', runtime[true])
    assert_includes trigger.fetch('push').fetch('paths-ignore'), 'acceptance/**'
    assert_includes trigger.fetch('push').fetch('paths-ignore'), 'development/installation.json'
    checks=YAML.load_file(File.expand_path('../.github/workflows/deployment-contracts.yml', __dir__))
    command=checks.fetch('jobs').fetch('windows-backup').fetch('steps').filter_map { |step| step['run'] }.join("\n")
    assert_includes command, 'laplace.ps1 test -Check'
    assert_includes command, 'acceptance-runner,desktop-storage-retention'
  end
  def test_cloud_waits_for_staging_runtime_results
    cloud=@jobs.fetch('deploy-cloud')
    assert_equal %w[deploy checks tests reads cloud-acquire], cloud.fetch('needs')
    %w[deploy checks tests reads].each { |job| assert_includes cloud.fetch('if'), "needs.#{job}.result == 'success'" }
    assert_includes cloud.fetch('if'), 'inputs.cloud == true'
  end
  def test_trusted_deployment_orchestration_uses_the_existing_host_without_replacing_sibling_checkouts
    runtime = YAML.load_file(File.expand_path('../.github/workflows/laplace.yml', __dir__))
    refute runtime.fetch('on', runtime[true]).key?('pull_request')
    %w[resolve qualify-engine].each do |name|
      job = @jobs.fetch(name)
      assert_equal %w[self-hosted laplace Laplace-Operations staging], job.fetch('runs-on')
      assert_equal 'Laplace-Operations', job.fetch('defaults').fetch('run').fetch('working-directory')
      checkout = job.fetch('steps').find { |step| step['uses']&.start_with?('actions/checkout@') }
      assert_equal 'Laplace-Operations', checkout.fetch('with').fetch('path')
      assert_equal false, checkout.fetch('with').fetch('persist-credentials')
    end
  end
  def test_both_targets_use_deployment_readback
    %w[checks checks-cloud].each do |name|
      steps=@jobs.fetch(name).fetch('steps')
      commands=steps.filter_map { |step| step['run'] }.join("\n")
      assert_equal './Laplace-Operations/verify.sh deployment', commands
      refute steps.any? { |step| step['continue-on-error'] }
    end
  end
  def test_runtime_activation_precedes_required_compatibility_readback
    [['deploy', 'checks'], ['deploy-cloud', 'checks-cloud']].each do |delivery, readback|
      steps=@jobs.fetch(delivery).fetch('steps')
      toolchain=steps.index { |step| step['uses']&.start_with?('dtolnay/rust-toolchain@') }
      infrastructure=steps.index { |step| step['name']=='build/install prepared artifacts and deploy database infrastructure' }
      activation=steps.index { |step| step['name']=='Deploy and verify the installed modular runtime' }
      assert toolchain && infrastructure && activation && toolchain < infrastructure && infrastructure < activation
      assert_equal '1.90.0', steps.fetch(toolchain).fetch('with').fetch('toolchain')
      refute steps.fetch(activation)['continue-on-error']
      assert_includes steps.fetch(activation).fetch('run'), 'installation/modular.py deploy'
      assert_includes @jobs.fetch(readback).fetch('needs'), delivery
    end
    refute @jobs.fetch('reads').fetch('steps').any? { |step| step['run']&.include?('modular.py deploy') }
  end
  def test_database_checks_run_against_the_deployed_revisions_after_readback
    tests=@jobs.fetch('tests')
    assert_equal %w[resolve deploy checks ingest], tests.fetch('needs')
    %w[deploy checks].each { |job| assert_includes tests.fetch('if'), "needs.#{job}.result == 'success'" }
    steps=tests.fetch('steps')
    assert_equal './Laplace-Operations/verify.sh tests', steps.filter_map { |step| step['run'] }.join("\n")
    refute steps.any? { |step| step['continue-on-error'] }
    refs=steps.filter_map { |step| step.dig('with', 'repository') && [step.dig('with', 'path'), step.dig('with', 'ref')] }.to_h
    assert_equal '${{ needs.deploy.outputs.postgres }}', refs.fetch('Laplace-postgres')
    assert_equal '${{ needs.deploy.outputs.engine }}', refs.fetch('Laplace-Engine')
    assert_equal '${{ needs.resolve.outputs.mcp }}', refs.fetch('Laplace-MCP')
  end
  def test_explicit_ingestion_requires_successful_readback
    assert_includes @jobs.fetch('ingest').fetch('if'), "needs.checks.result == 'success'"
    assert_includes @jobs.fetch('ingest').fetch('if'), "needs.deploy.outputs.ingest == 'true'"
  end
  def test_compatibility_cannot_be_skipped_before_a_successful_readback
    assert_includes @jobs.fetch('checks-cloud').fetch('if'), 'always()'
    assert_includes @jobs.fetch('checks-cloud').fetch('if'), "needs.deploy-cloud.result == 'success'"
    [['reads', 'checks'], ['reads-cloud', 'checks-cloud']].each do |reads, checks|
      assert_includes @jobs.fetch(reads).fetch('needs'), checks
      assert_includes @jobs.fetch(reads).fetch('if'), "needs.#{checks}.result == 'success'"
    end
  end
  def test_cloud_compute_is_acquired_and_released_for_the_run
    assert_equal './.github/workflows/cloud-lease.yml', @jobs.fetch('cloud-acquire').fetch('uses')
    assert_equal 'acquire', @jobs.fetch('cloud-acquire').fetch('with').fetch('operation')
    assert_equal 'release', @jobs.fetch('cloud-release').fetch('with').fetch('operation')
    assert_includes @jobs.fetch('cloud-release').fetch('if'), 'always()'
    %w[deploy-cloud checks-cloud ingest-cloud reads-cloud].each do |name|
      assert_includes @jobs.fetch('cloud-release').fetch('needs'), name
    end
  end
end
