require 'yaml'
require 'minitest/autorun'
class DeploymentWorkflow < Minitest::Test
  def setup
    @jobs = YAML.load_file(File.expand_path('../.github/workflows/laplace.yml', __dir__)).fetch('jobs')
  end
  def test_cloud_waits_for_staging_runtime_results
    cloud=@jobs.fetch('deploy-cloud')
    assert_equal %w[deploy checks reads cloud-acquire], cloud.fetch('needs')
    %w[deploy checks reads].each { |job| assert_includes cloud.fetch('if'), "needs.#{job}.result == 'success'" }
    assert_includes cloud.fetch('if'), 'inputs.cloud == true'
  end
  def test_both_targets_use_deployment_readback
    %w[checks checks-cloud].each do |name|
      steps=@jobs.fetch(name).fetch('steps')
      commands=steps.filter_map { |step| step['run'] }.join("\n")
      assert_equal './Laplace-Operations/verify.sh deployment', commands
      refute steps.any? { |step| step['continue-on-error'] }
    end
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
