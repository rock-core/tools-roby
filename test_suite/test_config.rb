$LOAD_PATH.unshift File.join(File.dirname(__FILE__))
$LOAD_PATH.unshift File.join(File.dirname(__FILE__), "../lib")
BASE_TEST_DIR=File.expand_path(File.dirname(__FILE__))

path=ENV['PATH'].split(':')
pkg_config_path=ENV['PKG_CONFIG_PATH'].split(':')

Dir.glob("#{BASE_TEST_DIR}/prefix.*") do |p|
    path << "#{p}/bin"
    pkg_config_path << "#{p}/lib/pkgconfig"
end
ENV['PATH'] = path.join(':')
ENV['PKG_CONFIG_PATH'] = pkg_config_path.join(':')


