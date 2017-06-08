require 'roby/app/installer'

if dir_name = ARGV.first
    if File.exist?(dir_name)
        Roby.error "#{dir_name} already exists"
        exit 1
    end

    FileUtils.mkdir_p dir_name
    Dir.chdir(dir_name) do
        Roby.app.app_dir = Dir.pwd
        installer = Roby::Installer.new(Roby.app)
        installer.install
    end
else
    Roby.app.app_dir = Roby.app.guess_app_dir || Dir.pwd
    installer = Roby::Installer.new(Roby.app)
    installer.install
end

