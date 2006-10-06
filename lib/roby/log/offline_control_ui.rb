# Form implementation generated from reading ui file 'lib/roby/log/offline_control.ui'
#
# Created: Fri Oct 6 15:45:03 2006
#      by: The QtRuby User Interface Compiler (rbuic)
#
# WARNING! All changes made in this file will be lost!


require 'Qt'

class DisplayControl < Qt::Dialog

    attr_reader :textLabel1_2
    attr_reader :lbl_file_name
    attr_reader :btn_file_open
    attr_reader :grp_display
    attr_reader :execution_flow
    attr_reader :relation_display
    attr_reader :relation_display_list
    attr_reader :btn_update
    attr_reader :grp_play
    attr_reader :sld_position
    attr_reader :dsp_position
    attr_reader :textLabel1
    attr_reader :edt_speed
    attr_reader :btn_seek_start
    attr_reader :btn_play
    attr_reader :btn_fast_forward
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
        @relation_display_list.setEnabled( false )
        @relation_display_list.setRootIsDecorated( true )
        @grp_displayLayout.addWidget(@relation_display_list)

        @layout5 = Qt::HBoxLayout.new(nil, 0, 6, 'layout5')
        @spacer3 = Qt::SpacerItem.new(231, 20, Qt::SizePolicy::Expanding, Qt::SizePolicy::Minimum)
        @layout5.addItem(@spacer3)

        @btn_update = Qt::PushButton.new(@grp_display, "btn_update")
        @layout5.addWidget(@btn_update)
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

        @layout8 = Qt::HBoxLayout.new(nil, 0, 6, 'layout8')

        @textLabel1 = Qt::Label.new(@grp_play, "textLabel1")
        @layout8.addWidget(@textLabel1)

        @edt_speed = Qt::LineEdit.new(@grp_play, "edt_speed")
        @edt_speed.setAlignment( Qt::LineEdit::AlignRight )
        @layout8.addWidget(@edt_speed)
        @spacer1 = Qt::SpacerItem.new(120, 20, Qt::SizePolicy::Expanding, Qt::SizePolicy::Minimum)
        @layout8.addItem(@spacer1)

        @btn_seek_start = Qt::PushButton.new(@grp_play, "btn_seek_start")
        @layout8.addWidget(@btn_seek_start)

        @btn_play = Qt::PushButton.new(@grp_play, "btn_play")
        @btn_play.setToggleButton( true )
        @layout8.addWidget(@btn_play)

        @btn_fast_forward = Qt::PushButton.new(@grp_play, "btn_fast_forward")
        @layout8.addWidget(@btn_fast_forward)

        @btn_seek_end = Qt::PushButton.new(@grp_play, "btn_seek_end")
        @layout8.addWidget(@btn_seek_end)
        @grp_playLayout.addLayout(@layout8)
        @DisplayControlLayout.addWidget(@grp_play)
        languageChange()
        resize( Qt::Size.new(586, 497).expandedTo(minimumSizeHint()) )
        clearWState( WState_Polished )

        Qt::Object.connect(@relation_display, SIGNAL("toggled(bool)"), @relation_display_list, SLOT("setEnabled(bool)") )
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
        @btn_update.setText( trUtf8("Update") )
        @grp_play.setTitle( trUtf8("Play") )
        @textLabel1.setText( trUtf8("Speed") )
        @edt_speed.setText( trUtf8("1") )
        @btn_seek_start.setText( trUtf8("|<<") )
        @btn_seek_start.setAccel( Qt::KeySequence.new(nil) )
        @btn_play.setText( trUtf8(">") )
        @btn_play.setAccel( Qt::KeySequence.new(nil) )
        @btn_fast_forward.setText( trUtf8(">>") )
        @btn_seek_end.setText( trUtf8(">>|") )
    end
    protected :languageChange


end
