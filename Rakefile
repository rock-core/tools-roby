$LOAD_PATH.unshift File.expand_path('lib', File.dirname(__FILE__))
require 'enumerator'
require 'roby/config'
require 'utilrb/doc/rake'

task :default => :setup
begin
    require 'hoe'
    namespace 'dist' do
        hoe = Hoe.spec 'roby' do |hoe|
            self.developer 'Sylvain Joyeux', 'sylvain.joyeux@m4x.org'

            self.summary = 'A plan-based control framework for autonomous systems'
            self.urls        = ["http://rock-robotics.org/master/api/tools/roby", "http://rock-robotics.org/stable/documentation/system"]
            self.description = <<-EOD
The Roby plan manager is currently developped from within the Robot Construction
Kit (http://rock-robotics.org). Have a look there. Additionally, the [Roby User
Guide](http://rock-robotics.org/api/tools/roby) is a good place to start wit
Roby.
            EOD
 
            self.extra_deps <<
                ['facets', '>= 2.0'] <<
                ['utilrb', '>= 1.3.1']

            self.extra_dev_deps <<
                ['webgen', '>= 0.5']
        end
	hoe.spec.extensions << 
	    'ext/droby/extconf.rb' <<
	    'ext/graph/extconf.rb'

        hoe.spec.description = hoe.summary
            
        Rake.clear_tasks(/doc/)
    end

rescue Exception => e
    puts e.backtrace.join("\n  ")
    if e.message !~ /\.rubyforge/
        STDERR.puts "cannot load the Hoe gem, or Hoe fails. Distribution is disabled"
        STDERR.puts "error message is: #{e.message}"
    end
end

def build_extension(name, soname = name)
    Dir.chdir("ext/#{name}") do
	extconf = "#{FileUtils::RUBY} extconf.rb"
	extconf << " --with-boost-dir=#{ENV['BOOST_DIR']}" if ENV['BOOST_DIR']
	if !system(extconf) || !system("make")
	    raise "cannot set up #{name} extension"
	end
    end
    FileUtils.ln_sf "../ext/#{name}/#{soname}.so", "lib/#{soname}.so"
end
def clean_extension(name, soname = name)
    puts "Cleaning ext/#{name}"
    Dir.chdir("ext/#{name}") do
	FileUtils.rm_f ["#{soname}.so", 'Makefile', 'mkmf.log']
	FileUtils.rm_f Dir.enum_for(:glob, '*.o').to_a
    end
end

task :cruise => [:setup, 'doc:recore', :test]

#########
# Test-related targets

desc 'run all tests'
task :test => ['test:core', 'test:distributed']

namespace 'test' do
    desc 'run tests on the Core'
    task 'core' => :setup do
        if !system("testrb test/suite_core.rb")
            puts "failed core suite"
            exit(1)
        end
    end
    desc 'run tests on Distributed Roby'
    task 'distributed' => :setup do
        if !system("testrb test/suite_distributed.rb")
            puts "failed droby suite"
            exit(1)
        end
    end
end

desc 'generate and build all the necessary files'
task :setup => :uic do
    build_extension 'droby', 'roby_marshalling'
    build_extension 'graph', 'roby_bgl'
end

desc 'remove all generated files'
task :clean => 'dist:clean' do
    clean_extension 'droby'
    clean_extension 'graph', 'bgl'
end

UIFILES = %w{gui/relations_view/relations.ui gui/relations_view/relations_view.ui gui/stepping.ui}
desc 'generate all Qt UI files using rbuic4'
task :uic do
    rbuic = 'rbuic4'
    if File.exists?('/usr/lib/kde4/bin/rbuic4')
        rbuic = '/usr/lib/kde4/bin/rbuic4'
    end

    UIFILES.each do |file|
	file = 'lib/roby/log/' + file
	if !system(rbuic, '-o', file.gsub(/\.ui$/, '_ui.rb'), file)
	    STDERR.puts "Failed to generate #{file}"
	end
    end
end

###########
# Documentation generation
#
# This redefines Hoe's targets for documentation, as the documentation
# generation is not flexible enough for us

# This is for the user's guide
begin
    require 'roby/app/rake'
    require 'webgen/webgentask'
    do_doc = true
rescue LoadError => e
    STDERR.puts "webgen is not available, documentation generation disabled"
    STDERR.puts "  Ruby reported the following load error: #{e.message}"
end

if do_doc
    namespace 'doc' do
        Utilrb.doc 'api', :include => ['lib/**/*.rb', 'ext/**/*.cc'],
            :exclude => ['lib/roby/test/**/*', 'lib/roby/app/**/*', 'lib/roby/log/gui/*'],
            :target_dir => 'doc/html/api',
            :title => 'Rock Core',
            :plugins => ['utilrb', 'roby']

        Webgen::WebgenTask.new('guide') do |website|
            website.clobber_outdir = true
            website.directory = File.join(Dir.pwd, 'doc', 'guide')
            website.config_block = lambda do |config|
                config['output'] = ['Webgen::Output::FileSystem', File.join(Dir.pwd, 'doc', 'html')]
            end
        end

        def plugins_documentation_generation(target_prefix)
            task "plugins_#{target_prefix}docs" do
                Roby::Rake.invoke_plugin_target("#{target_prefix}docs")
            end
        end
        desc 'generate the documentation for all installed plugins'
        plugins_documentation_generation ''
        desc 'remove the documentation for all installed plugins'
        plugins_documentation_generation 'clobber_'
        desc 'regenerate the documentation for all installed plugins'
        plugins_documentation_generation 're'

        desc 'generate all documentation'
        task 'all' => ['doc:guide', 'doc:api', 'doc:plugins_docs']
        desc 'removes all documentation'
        task 'clobber' do
            FileUtils.rm_rf File.join('doc', 'html')
        end

        desc 'regenerate all documentation'
        task 'redocs' do
            FileUtils.rm_f File.join('doc', 'guide', 'webgen.cache')
            FileUtils.rm_rf File.join('doc', 'html')
            if !system('rake', 'doc:all')
                raise "failed to regenerate documentation"
            end
        end
    end
    task 'redocs' => 'doc:redocs'
    task 'clobber_docs' => 'doc:clobber'
end
