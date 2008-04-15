#require 'rake/rdoctask'
require 'enumerator'
require 'hoe'
require 'roby/dist'

begin
    require 'hoe'
    Hoe.new('roby', Roby::VERSION) do |p|
        p.developer 'Sylvain Joyeux', 'sylvain.joyeux@m4x.org'

        p.summary = 'A robotic control framework'
        p.description = p.paragraphs_of('README.txt', 2..3).join("\n\n")
        p.url         = p.paragraphs_of('README.txt', 0).first.split(/\n/)[1..-1]
        p.changes     = p.paragraphs_of('History.txt', 0..1).join("\n\n")

        p.extra_deps << 'facets >= 2.0' << 'activesupport' << 'utilrb >= 1.1'
        p.rdoc_pattern = /^$/
    end
rescue LoadError
    puts "cannot load the Hoe gem, distribution is disabled"
end

def build_extension(name, soname = name)
    Dir.chdir("ext/#{name}") do
	extconf = "ruby extconf.rb"
	extconf << " --with-boost-dir=#{ENV['BOOST_DIR']}" if ENV['BOOST_DIR']
	if !system(extconf) || !system("make")
	    raise "cannot set up #{name} extension"
	end
    end
    FileUtils.ln_sf "../../ext/#{name}/#{soname}.so", "lib/roby/#{soname}.so"
end
def clean_extension(name, soname = name)
    puts "Cleaning ext/#{name}"
    Dir.chdir("ext/#{name}") do
	FileUtils.rm_f ["#{soname}.so", 'Makefile', 'mkmf.log']
	FileUtils.rm_f Dir.enum_for(:glob, '*.o').to_a
    end
end

task :cruise => [:setup, :recore_docs, :test]

#########
# Test-related targets

desc 'run all tests'
task :test => :test_core

desc 'run tests only on the Core'
task :test_core => :setup do
    if !system("testrb test/suite_core.rb")
	puts "failed core suite"
	exit(1)
    end
    if !system("testrb test/suite_distributed.rb")
	puts "failed droby suite"
	exit(1)
    end
end

desc 'generate and build all the necessary files'
task :setup => :uic do
    build_extension 'droby'
    build_extension 'graph', 'bgl'
end

desc 'remove all generated files'
task :clean do
    clean_extension 'droby'
    clean_extension 'graph', 'bgl'
end

UIFILES = %w{relations.ui relations_view.ui data_displays.ui replay_controls.ui basic_display.ui chronicle_view.ui}
desc 'generate all Qt UI files using rbuic4'
task :uic do
    UIFILES.each do |file|
	file = 'lib/roby/log/gui/' + file
	if !system('rbuic4', '-x', '-o', file.gsub(/\.ui$/, '_ui.rb'), file)
	    STDERR.puts "Failed to generate #{file}"
	end
    end
end

###########
# Documentation generation
#
# This redefines Hoe's targets for documentation, as the documentation
# generation is not flexible enough for us
#
# Plus, I don't like RDoc default template, and I much prefer allison's.

allison_path = `allison --path`.chomp.chomp
if allison_path.empty?
    allison_path = nil
end

Rake::RDocTask.new("core_docs") do |rdoc|
  rdoc.options << "--inline-source" << "--accessor" << "attribute" << "--accessor" << "attr_predicate"
  rdoc.rdoc_dir = 'doc/core'
  rdoc.title    = "Roby Core"
  if allison_path
      rdoc.template = allison_path
  else
      puts "warning: allison template not available, will use hefss instead"
      rdoc.template = 'hefss'
  end
  rdoc.options << '--main' << 'README.txt'
  rdoc.rdoc_files.include('README.txt', 'TODO.txt', 'History.txt')
  rdoc.rdoc_files.include('lib/**/*.rb', 'ext/**/*.cc')
  rdoc.rdoc_files.exclude('lib/roby/test/**/*', 'lib/roby/app/**/*', 'lib/roby/log/gui/*')
end

