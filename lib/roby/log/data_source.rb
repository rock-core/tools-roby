
module Roby::Log
    class DataSource
	attr_accessor :files
	attr_accessor :type
	attr_accessor :source
	def initialize(files = [], type = nil, source = nil)
	    @files, @type, @source = files, type, source
	end
    end
end

