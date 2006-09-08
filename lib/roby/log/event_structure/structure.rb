
class Roby::Display::EventStructureServer
    class Column
	attr_reader :x, :width, :display, :lines
	def initialize(x, display)
	    @display = display
	    @x	= x
	    @lines	= []

	    @width = MINWIDTH
	end

	attr_accessor :next_column
	def each(&iterator)
	    if next_column
		yield(self.next_column)
		next_column.each(&iterator)
	    end
	    self
	end
	include Enumerable

	def each_line(&iterator); lines.each(&iterator) end
	def parent_of?(c); !!find { |child| child == c } end
	def empty?; lines.all? { |l| !l } end

	def width=(new)
	    offset = new - width
	    @width = new

	    # Adjust column positions
	    each { |col| col.x += offset }

	    # Adjust spanning
	    lines.each_with_index do |element, line_idx|
		next unless element
		update_element_span(element, line_idx)
	    end
	end

	def update_element_span(element, index)
	    return unless lines[index] == element
	    remaining = element.span - width
	    if remaining <= 0
		remove(element)
	    elsif next_column
		next_column.update_element_span(element, index)
	    else
		display.remaining[index] = [element, remaining]
	    end
	end

	def x=(new)
	    offset = new - x
	    @x = new

	    lines.compact.each do |element|
		element.move(element.x + offset, element.y) if element.column == self
	    end
	    next_column.x += offset if next_column
	end

	def add(element)
	    if element.width > width
		self.width = element.width * 1.2
	    end
	    raise if lines.index(element)

	    line_idx = (0..(lines.size - 1)).find do |line_idx|
		allocate(line_idx, element, element.span)
	    end

	    unless line_idx
		line_idx = lines.size
		display.newline
		allocate(line_idx, element, element.span)
	    end

	    element.move(x, display.margin + line_idx * display.line_height)
	end

	def allocate(index, element, span)
	    return if lines[index]

	    remaining = span - width
	    found = if remaining <= 0
			display.remaining[index] = [nil, 0] if !next_column
			true
		    elsif !next_column
			display.remaining[index] = [element, remaining]
			true
		    else
			next_column.allocate(index, element, remaining)
		    end

	    if found
		lines[index] = element
		true
	    end
	end

	def remove(element, line_idx = nil)
	    return unless (line_idx ||= lines.index(element))
	    return if lines[line_idx] != element

	    lines[line_idx] = nil
	    if next_column
		next_column.remove(element, line_idx)
	    elsif display.remaining[line_idx].first == element
		display.remaining[line_idx] = [nil, 0]
	    end
	end
    end

    class Element
	attr_reader :next_elements, :display
	def initialize(column, display)
	    @display	= display
	    @next_elements	= Set.new
	    @parent		= nil
	    @children	= Array.new

	    self.column = column
	end

	def column
	    display.each_column do |col|
		return col if col.lines.index(self)
	    end
	    nil
	end

	def x; group.x end
	def y; group.y end

	def column=(new)
	    column_update(new)
	    propagate_column if column
	    display.check_structure
	    new
	end

	def column_update(new)
	    raise "trying to set the column of a non-root element" if parent
	    if column
		column.remove(self)
		# check that nothing is broken ...
		display.each_column { |c| raise if c.lines.index(self) }
	    end

	    new.add(self) if new
	end

	def propagate_column
	    seen = Set.new
	    seen << self
	    enum_bfs(:each_following_element).each_edge do |from, to|
		next if seen.include?(to)
		seen << to
		next_column = (from.column.next_column if from.column) || display.newcolumn
		to.column_update(next_column) unless next_column.parent_of?(to.column)
	    end
	end
	def each_following_element(&iterator)
	    next_elements.each(&iterator)
	end

	protected :column_update

	attr_accessor :parent
	attr_reader   :children
	def root; parent || self end
	def child(element)
	    element.column = nil
	    element.parent = self
	    children << element
	end
    end
end


