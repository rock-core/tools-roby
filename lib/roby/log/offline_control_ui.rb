# Form implementation generated from reading ui file 'lib/roby/log/offline_control.ui'
#
# Created: Sun Oct 29 18:26:51 2006
#      by: The QtRuby User Interface Compiler (rbuic)
#
# WARNING! All changes made in this file will be lost!


require 'Qt'

class DisplayControl < Qt::Dialog

    slots 'languageChange()',
    'seek_start()',
    'seek_end()',
    'seek_previous()',
    'open()',
    'new_display()',
    'play()',
    'faster()',
    'play_step()',
    'slower()',
    'seek_next()',
    'change_play_mode()'

    attr_reader :textLabel1_2
    attr_reader :lbl_file_name
    attr_reader :btn_file_open
    attr_reader :grp_display
    attr_reader :execution_flow
    attr_reader :relation_display
    attr_reader :relation_display_list
    attr_reader :btn_new_display
    attr_reader :grp_play
    attr_reader :sld_position
    attr_reader :dsp_position
    attr_reader :btn_grp_playmode
    attr_reader :btn_play_time
    attr_reader :btn_play_events
    attr_reader :textLabel1
    attr_reader :edt_speed
    attr_reader :btn_slower
    attr_reader :btn_play
    attr_reader :btn_faster
    attr_reader :btn_seek_start
    attr_reader :btn_seek_previous
    attr_reader :btn_seek_next
    attr_reader :btn_seek_end


    def initialize(parent = nil, name = nil, modal = false, fl = 0)
        super

        if name.nil?
        	setName("DisplayControl")
        end

        @DisplayControlLayout = Qt::VBoxLayout.new(self, 11, 6, 'DisplayControlLayout')

        @layout7 = Qt::HBoxLayout.new(nil, 0, 6, 'layout7')

        @textLabel1_2 = Qt::Label.new(self, "textLabel1_2")
        @layout7.addWidget(@textLabel1_2)

        @lbl_file_name = Qt::Label.new(self, "lbl_file_name")
        @lbl_file_name.setSizePolicy( Qt::SizePolicy.new(3, 5, 0, 0, @lbl_file_name.sizePolicy().hasHeightForWidth()) )
        @layout7.addWidget(@lbl_file_name)

        @btn_file_open = Qt::PushButton.new(self, "btn_file_open")
        @layout7.addWidget(@btn_file_open)
        @DisplayControlLayout.addLayout(@layout7)

        @grp_display = Qt::ButtonGroup.new(self, "grp_display")
        @grp_display.setEnabled( false )
        @grp_display.setColumnLayout( 0, Qt::Vertical )
        @grp_display.layout().setSpacing(6)
        @grp_display.layout().setMargin(11)
        @grp_displayLayout = Qt::VBoxLayout.new(@grp_display.layout() )
        @grp_displayLayout.setAlignment( AlignTop )

        @execution_flow = Qt::RadioButton.new(@grp_display, "execution_flow")
        @execution_flow.setChecked( true )
        @grp_displayLayout.addWidget(@execution_flow)

        @relation_display = Qt::RadioButton.new(@grp_display, "relation_display")
        @grp_displayLayout.addWidget(@relation_display)

        @relation_display_list = Qt::ListView.new(@grp_display, "relation_display_list")
        @relation_display_list.addColumn(trUtf8("Relation"))
        @relation_display_list.addColumn(trUtf8("Color"))
        @relation_display_list.setEnabled( false )
        @relation_display_list.setRootIsDecorated( true )
        @grp_displayLayout.addWidget(@relation_display_list)

        @layout5 = Qt::HBoxLayout.new(nil, 0, 6, 'layout5')
        @spacer3 = Qt::SpacerItem.new(231, 20, Qt::SizePolicy::Expanding, Qt::SizePolicy::Minimum)
        @layout5.addItem(@spacer3)

        @btn_new_display = Qt::PushButton.new(@grp_display, "btn_new_display")
        @layout5.addWidget(@btn_new_display)
        @grp_displayLayout.addLayout(@layout5)
        @DisplayControlLayout.addWidget(@grp_display)

        @grp_play = Qt::GroupBox.new(self, "grp_play")
        @grp_play.setEnabled( false )
        @grp_play.setColumnLayout( 0, Qt::Vertical )
        @grp_play.layout().setSpacing(6)
        @grp_play.layout().setMargin(11)
        @grp_playLayout = Qt::VBoxLayout.new(@grp_play.layout() )
        @grp_playLayout.setAlignment( AlignTop )

        @layout4 = Qt::HBoxLayout.new(nil, 0, 6, 'layout4')

        @sld_position = Qt::Slider.new(@grp_play, "sld_position")
        @sld_position.setOrientation( Qt::Slider::Horizontal )
        @layout4.addWidget(@sld_position)

        @dsp_position = Qt::LCDNumber.new(@grp_play, "dsp_position")
        @dsp_position.setNumDigits( 6 )
        @dsp_position.setSegmentStyle( Qt::LCDNumber::Flat )
        @dsp_position.setProperty( "value", Qt::Variant.new(0 ) )
        @layout4.addWidget(@dsp_position)
        @grp_playLayout.addLayout(@layout4)

        @layout9 = Qt::HBoxLayout.new(nil, 0, 6, 'layout9')

        @btn_grp_playmode = Qt::ButtonGroup.new(@grp_play, "btn_grp_playmode")
        @btn_grp_playmode.setFrameShape( Qt::ButtonGroup::NoFrame )
        @btn_grp_playmode.setColumnLayout( 0, Qt::Vertical )
        @btn_grp_playmode.layout().setSpacing(6)
        @btn_grp_playmode.layout().setMargin(11)
        @btn_grp_playmodeLayout = Qt::VBoxLayout.new(@btn_grp_playmode.layout() )
        @btn_grp_playmodeLayout.setAlignment( AlignTop )

        @btn_play_time = Qt::RadioButton.new(@btn_grp_playmode, "btn_play_time")
        @btn_play_time.setChecked( true )
        @btn_grp_playmodeLayout.addWidget(@btn_play_time)

        @btn_play_events = Qt::RadioButton.new(@btn_grp_playmode, "btn_play_events")
        @btn_grp_playmodeLayout.addWidget(@btn_play_events)
        @layout9.addWidget(@btn_grp_playmode)

        @layout12 = Qt::VBoxLayout.new(nil, 0, 6, 'layout12')

        @layout11 = Qt::HBoxLayout.new(nil, 0, 6, 'layout11')

        @textLabel1 = Qt::Label.new(@grp_play, "textLabel1")
        @layout11.addWidget(@textLabel1)

        @edt_speed = Qt::LineEdit.new(@grp_play, "edt_speed")
        @edt_speed.setSizePolicy( Qt::SizePolicy.new(1, 0, 1, 0, @edt_speed.sizePolicy().hasHeightForWidth()) )
        @edt_speed.setMaximumSize( Qt::Size.new(80, 32767) )
        @edt_speed.setAlignment( Qt::LineEdit::AlignRight )
        @layout11.addWidget(@edt_speed)

        @btn_slower = Qt::PushButton.new(@grp_play, "btn_slower")
        @layout11.addWidget(@btn_slower)

        @btn_play = Qt::PushButton.new(@grp_play, "btn_play")
        @btn_play.setSizePolicy( Qt::SizePolicy.new(3, 0, 2, 0, @btn_play.sizePolicy().hasHeightForWidth()) )
        @btn_play.setToggleButton( true )
        @layout11.addWidget(@btn_play)

        @btn_faster = Qt::PushButton.new(@grp_play, "btn_faster")
        @layout11.addWidget(@btn_faster)
        @layout12.addLayout(@layout11)

        @layout9_2 = Qt::HBoxLayout.new(nil, 0, 6, 'layout9_2')

        @btn_seek_start = Qt::PushButton.new(@grp_play, "btn_seek_start")
        @layout9_2.addWidget(@btn_seek_start)

        @btn_seek_previous = Qt::PushButton.new(@grp_play, "btn_seek_previous")
        @layout9_2.addWidget(@btn_seek_previous)

        @btn_seek_next = Qt::PushButton.new(@grp_play, "btn_seek_next")
        @layout9_2.addWidget(@btn_seek_next)

        @btn_seek_end = Qt::PushButton.new(@grp_play, "btn_seek_end")
        @layout9_2.addWidget(@btn_seek_end)
        @layout12.addLayout(@layout9_2)
        @layout9.addLayout(@layout12)
        @grp_playLayout.addLayout(@layout9)
        @DisplayControlLayout.addWidget(@grp_play)
        languageChange()
        resize( Qt::Size.new(475, 671).expandedTo(minimumSizeHint()) )
        clearWState( WState_Polished )

        Qt::Object.connect(@relation_display, SIGNAL("toggled(bool)"), @relation_display_list, SLOT("setEnabled(bool)") )
        Qt::Object.connect(@btn_seek_start, SIGNAL("clicked()"), self, SLOT("seek_start()") )
        Qt::Object.connect(@btn_seek_end, SIGNAL("clicked()"), self, SLOT("seek_end()") )
        Qt::Object.connect(@btn_seek_previous, SIGNAL("clicked()"), self, SLOT("seek_previous()") )
        Qt::Object.connect(@btn_seek_next, SIGNAL("clicked()"), self, SLOT("seek_next()") )
        Qt::Object.connect(@btn_file_open, SIGNAL("clicked()"), self, SLOT("open()") )
        Qt::Object.connect(@btn_play, SIGNAL("clicked()"), self, SLOT("play()") )
        Qt::Object.connect(@btn_faster, SIGNAL("clicked()"), self, SLOT("faster()") )
        Qt::Object.connect(@btn_new_display, SIGNAL("clicked()"), self, SLOT("new_display()") )
        Qt::Object.connect(@btn_slower, SIGNAL("clicked()"), self, SLOT("slower()") )
        Qt::Object.connect(@btn_play_time, SIGNAL("toggled(bool)"), self, SLOT("change_play_mode()") )
        Qt::Object.connect(@btn_play_events, SIGNAL("toggled(bool)"), self, SLOT("change_play_mode()") )
    end

    #
    #  Sets the strings of the subwidgets using the current
    #  language.
    #
    def languageChange()
        setCaption(trUtf8("Display control"))
        @textLabel1_2.setText( trUtf8("File") )
        @lbl_file_name.setText( nil )
        @btn_file_open.setText( trUtf8("Open") )
        @grp_display.setTitle( trUtf8("Display") )
        @execution_flow.setText( trUtf8("execution flow display") )
        @relation_display.setText( trUtf8("relation display") )
        @relation_display_list.header().setLabel( 0, trUtf8("Relation") )
        @relation_display_list.header().setLabel( 1, trUtf8("Color") )
        @btn_new_display.setText( trUtf8("New") )
        @grp_play.setTitle( trUtf8("Play") )
        @btn_grp_playmode.setTitle( nil )
        @btn_play_time.setText( trUtf8("time") )
        @btn_play_events.setText( trUtf8("events") )
        @textLabel1.setText( trUtf8("Speed") )
        @edt_speed.setText( trUtf8("1") )
        @btn_slower.setText( trUtf8("<<") )
        @btn_play.setText( trUtf8(">") )
        @btn_play.setAccel( Qt::KeySequence.new(nil) )
        @btn_faster.setText( trUtf8(">>") )
        @btn_seek_start.setText( trUtf8("|<<") )
        @btn_seek_start.setAccel( Qt::KeySequence.new(nil) )
        @btn_seek_previous.setText( trUtf8("|<") )
        @btn_seek_previous.setAccel( Qt::KeySequence.new(nil) )
        @btn_seek_next.setText( trUtf8(">|") )
        @btn_seek_end.setText( trUtf8(">>|") )
    end
    protected :languageChange


    def seek_start(*k)
        print("DisplayControl.seek_start(): Not implemented yet.\n")
    end

    def seek_end(*k)
        print("DisplayControl.seek_end(): Not implemented yet.\n")
    end

    def seek_previous(*k)
        print("DisplayControl.seek_previous(): Not implemented yet.\n")
    end

    def open(*k)
        print("DisplayControl.open(): Not implemented yet.\n")
    end

    def new_display(*k)
        print("DisplayControl.new_display(): Not implemented yet.\n")
    end

    def play(*k)
        print("DisplayControl.play(): Not implemented yet.\n")
    end

    def faster(*k)
        print("DisplayControl.faster(): Not implemented yet.\n")
    end

    def play_step(*k)
        print("DisplayControl.play_step(): Not implemented yet.\n")
    end

    def slower(*k)
        print("DisplayControl.slower(): Not implemented yet.\n")
    end

    def seek_next(*k)
        print("DisplayControl.seek_next(): Not implemented yet.\n")
    end

    def change_play_mode(*k)
        print("DisplayControl.change_play_mode(): Not implemented yet.\n")
    end

end
