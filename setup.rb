require 'fileutils'

BASEDIR = File.expand_path( File.dirname(__FILE__) )

Dir.new( extdir = File.join(BASEDIR, 'ext') ).each do |ext|
    ext = File.join(extdir, ext)
    next unless File.file?( File.join(ext, 'extconf.rb') )
    Dir.chdir(ext) do
	system('ruby extconf.rb')
	system('make')

	Dir.glob("*.so") do |sofile|
	    FileUtils.rm_f File.join(BASEDIR, "lib", sofile)
	    FileUtils.ln_s File.join(ext, sofile), File.join(BASEDIR, "lib", sofile)
	end
    end
end

