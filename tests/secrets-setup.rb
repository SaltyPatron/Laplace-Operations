require 'tmpdir'
require 'fileutils'
require 'open3'

source = File.read(File.expand_path('../secrets/install.sh', __dir__))
Dir.mktmpdir('secrets-setup-', ENV.fetch('TMPDIR')) do |work|
  env = {'BASE' => work, 'HERE' => '/fixture', 'VW_IMAGE' => 'fixture/image'}
  vaultwarden = source.split('echo "== 2. Vaultwarden"', 2).fetch(1).split('docker compose -f', 2).first
  run = lambda do |code, success|
    output, status = Open3.capture2e(env, 'bash', '-euc', code)
    raise "unexpected setup result: #{output}" unless status.success? == success
  end
  run.call(vaultwarden, true)
  compose = "#{work}/vaultwarden/compose.yaml"
  closed = File.read(compose).sub('SIGNUPS_ALLOWED: "true"', 'SIGNUPS_ALLOWED: "false"')
  File.write(compose, closed)
  run.call(vaultwarden, true)
  raise 'repeat setup changed configuration' unless File.read(compose) == closed
  File.unlink(compose)
  File.write("#{work}/vaultwarden/data/db.sqlite3", 'existing database')
  run.call(vaultwarden, false)
  raise 'recreated config over existing data' if File.exist?(compose)

  config = "#{work}/openbao.hcl"
  bao = source.split('install -d -m 700 -o openbao -g openbao "$BASE/openbao/data"', 2).fetch(1)
              .split('systemctl enable --now openbao', 2).first.gsub('/etc/openbao/openbao.hcl', config)
  FileUtils.mkdir_p("#{work}/openbao/data")
  existing = "audit \"file\" \"file\" { options { file_path = \"/existing/audit.log\" } }\n"
  File.write(config, existing)
  run.call("existing_bao_config=1\n#{bao}", true)
  raise 'audit configuration lost' unless File.read(config) == existing
  File.unlink(config)
  File.write("#{work}/openbao/data/raft.db", 'existing data')
  run.call("existing_bao_config=0\n#{bao}", false)
  raise 'recreated Bao configuration over existing data' if File.exist?(config)
end
puts 'PASS setup preserves closed signups and Bao audit configuration; missing configuration over existing data fails'
