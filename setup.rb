
BASEDIR = File.expand_path( File.dirname(__FILE__) )

Dir.new( extdir = File.join(BASEDIR, 'ext') ).each do |ext|
    ext = File.join(extdir, ext)
    next unless File.file?( File.join(ext, 'extconf.rb') )
    Dir.chdir(ext) do
	system('ruby extconf.rb')
	system('make')
    end
end

