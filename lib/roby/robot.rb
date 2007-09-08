module Robot
    class << self
	attr_accessor :logger
    end
    extend Logger::Forward
end

