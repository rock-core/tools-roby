def find_data(name)
    Roby::State.datadirs.each do |dir|
	path = File.join(dir, name)
	return path if File.exists?(path)
    end
    raise Errno::ENOENT, "no such file #{path}"
end

