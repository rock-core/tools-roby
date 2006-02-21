require 'rake/rdoctask'

def add_to_path(pathvar, value)
    pathvalue = ENV[pathvar]
    if !pathvalue || pathvalue.empty?
        ENV[pathvar] = value
    else
        ENV[pathvar] += ":#{value}"
    end
end

def add_prefix_pkgconfig(prefix)
    pkgconfig_dir = "#{prefix}/lib/pkgconfig"
    if File.directory?(pkgconfig_dir)
        add_to_path('PKG_CONFIG_PATH', pkgconfig_dir)
    end
end


BASEDIR = File.expand_path(File.join(File.dirname(__FILE__), "test_suite"))

def mockup_module(mod, genopt = nil, configopt = nil)
    moddir = "#{BASEDIR}/modules/#{mod}"
    prefixdir = "#{BASEDIR}/prefix.#{mod}"
    
    file "#{moddir}/.genom/genom-stamp" => "#{moddir}/#{mod}.gen" do
        Dir.chdir(moddir) do
            unless system("genom #{genopt} #{mod}.gen")
                raise "Unable to build and install the #{mod} module"
            end
        end
    end

    file "#{moddir}/config.status" => "#{moddir}/.genom/genom-stamp" do
        Dir.chdir(moddir) do
            unless system("./configure #{configopt} --prefix=#{prefixdir} --disable-static")
                raise "Unable to configure the #{mod} module"
            end
        end
    end

    task mod => "#{moddir}/config.status" do
        Dir.chdir("#{moddir}") do
            unless
                system("make") && 
                system("make install")
                raise "Unable to build and install the #{mod} module"
            end
        end
        add_prefix_pkgconfig prefixdir
    end
    task :test_build => mod

    task "#{mod}_clean" do
        FileUtils.rm_rf prefixdir
        Dir.chdir("#{moddir}") do
            unless
                system("make distclean") && 
                system("genom-clean")
                raise "Unable to clean the #{mod} module"
            end
        end
    end
    task :test_clean => "#{mod}_clean"
end

# Generate, build and install the mockup module
# It is supposed to depend on nothing
mockup_module "mockup"

Rake::RDocTask.new("rdoc") do |rdoc|
  rdoc.options << "--inline-source"
  rdoc.rdoc_dir = 'html'
  rdoc.title    = "Roby"
  rdoc.options << '-T' << 'hefss'
  #rdoc.options << '--main' << 'README'
  #rdoc.rdoc_files.include('README', 'CHANGES')
  rdoc.rdoc_files.include('lib/**/*.rb', 'doc/**/*.rdoc')
  rdoc.rdoc_files.exclude('doc/**/*_attrs.rdoc')
end


