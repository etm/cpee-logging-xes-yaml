Gem::Specification.new do |s|
  s.name             = "cpee-logging-xes-yaml"
  s.version          = "1.0.3"
  s.platform         = Gem::Platform::RUBY
  s.license          = "LGPL-3.0"
  s.summary          = "Logging for the cloud process execution engine (cpee.org)"

  s.description      = "see http://cpee.org"

  s.files            = Dir['{server/**/*,tools/**/*,lib/**/*}'] + %w(LICENSE Rakefile cpee-logging-xes-yaml.gemspec README.md AUTHORS)
  s.require_path     = 'lib'
  s.extra_rdoc_files = ['README.md']
  s.bindir           = 'tools'
  s.executables      = ['cpee-logging-xes-yaml']

  s.required_ruby_version = '>=2.4.0'

  s.authors          = ['Juergen eTM Mangler','Florian Stertz']

  s.email            = 'juergen.mangler@gmail.com'
  s.homepage         = 'http://cpee.org/'

  s.add_runtime_dependency 'riddl', '~> 0.99'
  s.add_runtime_dependency 'json', '~> 2.1'
  s.add_runtime_dependency 'cpee', '~> 1', '>= 1.5'
end
