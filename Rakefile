require 'rake/rdoctask'
require 'enumerator'

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

task :setup => :uic do
    build_extension 'droby'
    build_extension 'graph', 'bgl'
end
task :clean do
    clean_extension 'droby'
    clean_extension 'graph', 'bgl'
end

Rake::RDocTask.new("core_docs") do |rdoc|
  rdoc.options << "--inline-source" << "--accessor" << "attribute" << "--accessor" << "attr_predicate"
  rdoc.rdoc_dir = 'html'
  rdoc.title    = "Roby Core"
  rdoc.options << '-T' << 'hefss'
  rdoc.options << '--main' << 'README'
  rdoc.rdoc_files.include('README', 'TODO')
  rdoc.rdoc_files.include('lib/**/*.rb', 'doc/**/*.rdoc', 'ext/**/*.cc')
  rdoc.rdoc_files.exclude('lib/roby/test/**/*', 'lib/roby/app/**/*', 'lib/roby/log/gui/*')
end

UIFILES = %w{relations.ui relations_view.ui data_displays.ui replay_controls.ui basic_display.ui}
task :uic do
    UIFILES.each do |file|
	file = 'lib/roby/log/gui/' + file
	if !system('rbuic4', '-x', '-o', file.gsub(/\.ui$/, '_ui.rb'), file)
	    STDERR.puts "Failed to generate #{file}"
	end
    end
end

