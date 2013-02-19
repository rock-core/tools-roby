require 'roby/app/installer'

Roby.app.app_dir = Roby.app.guess_app_dir || Dir.pwd
installer = Roby::Installer.new(Roby.app)
installer.install

