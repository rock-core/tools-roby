$LOAD_PATH.unshift File.expand_path('lib', File.dirname(__FILE__))
require 'enumerator'
require 'hoe'
require 'roby/config'

begin
    require 'hoe'
    namespace 'dist' do
        hoe = Hoe.spec 'roby' do
            self.developer 'Sylvain Joyeux', 'sylvain.joyeux@m4x.org'

            self.summary = 'A plan-based control framework for autonomous systems'
            self.url         = paragraphs_of('README.txt', 1).join("\n\n")
            self.description = paragraphs_of('README.txt', 3..5).join("\n\n")
            self.description +=
"\n\nSee the README.txt file at http://roby.rubyforge.org for more
informations, including links to tutorials and demonstration videos"
            self.changes     = paragraphs_of('History.txt', 0..1).join("\n\n")
            self.post_install_message = paragraphs_of('README.txt', 2).join("\n\n")

            self.extra_deps <<
                ['facets', '>= 2.0'] <<
                ['utilrb', '>= 1.3.1']

            self.extra_dev_deps <<
                ['rdoc', '>= 2.4'] <<
                ['webgen', '>= 0.5'] <<

            self.need_rdoc = false
        end
	hoe.spec.extensions << 
	    'ext/droby/extconf.rb' <<
	    'ext/graph/extconf.rb'

        hoe.spec.extra_rdoc_files =
            hoe.spec.files.grep /(\.rdoc|\.cc|\.hh|\.rb|\.txt)$/

        hoe.spec.description = hoe.summary
            
        hoe.spec.rdoc_options << 
            '--main' << 'README.txt' <<
            "--accessor" << "attribute" << 
            "--accessor" << "attr_predicate"

        Rake.clear_tasks(/dist:publish_docs/)
        Rake.clear_tasks(/dist:(re|clobber_|)docs/)

        desc 'update the pages that are displayed on doudou.github.com/roby'
        task "publish_docs" => ["doc:guide", "doc:api"] do
            if !system( File.join("doc", "misc", "update_github") )
                raise "cannot update the gh-pages branch"
            end
        end
    end
rescue Exception => e
    puts "cannot setup Hoe, distribution is disabled"
    puts "error is: #{e.message}"
end

def build_extension(name, soname = name)
    Dir.chdir("ext/#{name}") do
	extconf = "ruby extconf.rb"
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

UIFILES = %w{relations.ui relations_view.ui data_displays.ui replay_controls.ui basic_display.ui chronicle_view.ui}
desc 'generate all Qt UI files using rbuic4'
task :uic do
    rbuic = 'rbuic4'
    if File.exists?('/usr/lib/kde4/bin/rbuic4')
        rbuic = '/usr/lib/kde4/bin/rbuic4'
    end

    UIFILES.each do |file|
	file = 'lib/roby/log/gui/' + file
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
    require 'webgen/webgentask'
    require 'rdoc/task'
    do_doc = true
rescue LoadError => e
    STDERR.puts "webgen and/or the rdoc Gem are not available, documentation generation disabled"
    STDERR.puts "  Ruby reported the following load error: #{e.message}"
end

if do_doc
    namespace 'doc' do
        require 'roby/app/rake'
        RDoc::Task.new("api") do |rdoc|
          rdoc.rdoc_dir = 'doc/html/api'
          rdoc.title    = "Roby Core"
          rdoc.options << '--show-hash'
          rdoc.rdoc_files.include('lib/**/*.rb', 'ext/**/*.cc')
          rdoc.rdoc_files.exclude('lib/roby/test/**/*', 'lib/roby/app/**/*', 'lib/roby/log/gui/*')
        end

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

        desc 'regenerate all documentation'
        task 'redocs' do
            Rake::Task['clobber_docs'].invoke
            if !system('rake', 'doc:all')
                raise "failed to regenerate documentation"
            end
        end
    end

    task 'docs' => 'doc:all'
    task 'clobber_docs' => ['doc:clobber_guide', 'doc:clobber_api', 'doc:plugins_clobber_docs']
    task 'redocs' => 'doc:redocs'
end

