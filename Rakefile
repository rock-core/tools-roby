task :default
package_name = 'roby'

begin
    require 'hoe'
    Hoe::RUBY_FLAGS.gsub! /-w/, ''

    hoe_spec = Hoe.spec package_name do |hoe|
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

        self.test_globs = ['test/suite_core.rb']
    end
    Rake.clear_tasks(/^default$/)
    Rake.clear_tasks(/^doc$/)
rescue LoadError => e
    STDERR.puts "The Hoe gem cannot be loaded. Some distribution functionality will not be available"
    STDERR.puts "(such as e.g. gem packaging) will not be available, but the package should still"
    STDERR.puts "be functional"
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

require 'rake/extensiontask'

Rake::ExtensionTask.new 'roby_marshalling' do |ext|
    if ENV['BOOST_DIR']
        ext.config_options << "--with-boost-dir=#{ENV['BOOST_DIR']}" 
    end
end

Rake::ExtensionTask.new 'roby_bgl' do |ext|
    if ENV['BOOST_DIR']
        ext.config_options << "--with-boost-dir=#{ENV['BOOST_DIR']}" 
    end
end

task :default => :compile
task :compile => :uic

###########
# Documentation generation
#
# This redefines Hoe's targets for documentation, as the documentation
# generation is not flexible enough for us

# This is for the user's guide
begin
    require 'utilrb/doc/rake'
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
        desc 'generate all documentation'
        task 'all' => ['doc:guide', 'doc:api']
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
