require 'roby/app/installer'

installer = Roby::Installer.new(Roby.app.app_dir || Dir.pwd)
installer.install([])

