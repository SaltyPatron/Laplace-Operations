require 'yaml'
require 'minitest/autorun'
class DeploymentWorkflow < Minitest::Test
  def setup
    @jobs = YAML.load_file(File.expand_path('../.github/workflows/laplace.yml', __dir__)).fetch('jobs')
  end
  def test_production_waits_for_staging_runtime_results
    production=@jobs.fetch('deploy-production')
    assert_equal %w[deploy checks reads], production.fetch('needs')
    %w[deploy checks reads].each { |job| assert_includes production.fetch('if'), "needs.#{job}.result == 'success'" }
    assert_includes production.fetch('if'), 'inputs.production == true'
  end
  def test_both_targets_use_deployment_readback
    %w[checks checks-production].each do |name|
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
end
