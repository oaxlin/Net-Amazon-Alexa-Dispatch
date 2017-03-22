package Amazon::Alexa::Dispatch;
use strict;
use warnings;
use JSON;
use Net::OAuth2;
use Time::Piece;
use URI::Escape;
use Clone qw{clone};
use Tie::IxHash;

my $me = 'Amazon::Alexa::Dispatch';
my $dispatch_type; # currently CGI only

=head1 NAME

Amazon::Alexa::Dispatch - Perl extensions for creating an Alexa skill

=head1 SYNOPSIS

  use Amazon::Alexa::Dispatch;

  Amazon::Alexa::Dispatch->new({
      dispatch=>[
          'Amazon::Alexa::SomePlugin',
          'Amazon::Alexa::AnotherPlugin'
      ],
      skillName=>'YourSkillName',
    })->dispatch_CGI;

=head1 DESCRIPTION

  A Perl module which provides a simple and lightweight interface to the Amazon
  Alexa Skills Kit

=head1 METHODS

  A list of methods available

=head2 new

  Create a new instance of Disptach.

=over

=over

=item skillName

  The name you wish to give this Alexa skill.  Used when displaying documentation.

=item dispatch [array]

  Any additional plugins you wish to dispatch to.  If you do not include any plugins
  then this module will only be able to perform Hello requests.

  If multiple plugins share the same method calls, the one listed first will be used.

=item token_dispatch

  By default uses the first plugin in your list.  If you wish to use a different
  plugin for token creation/authentication then list that module here.

=back

=back

=cut

sub new {
    my $class = shift;
    my $args = shift;
    my $dispatch = $args->{'dispatch'};
    $dispatch = [$dispatch] if $dispatch && !ref $dispatch;
    push @$dispatch, 'Amazon::Alexa::Dispatch';
    my $node = {
        configFile => $args->{'configFile'},
        skillName => $args->{'skillName'} // 'SKILL',
        dispatch => $dispatch,
        token_dispatch => $args->{'token_dispatch'} || $dispatch->[0],
    };
    my $config = { 'Amazon::Alexa::Dispatch' => { alexa_token => 'fake'} };
    if ($args->{'configFile'}) {
      local $/;
      open( my $fh, '<', $args->{'configFile'} );
      my $json_text   = <$fh>;
      $config = decode_json( $json_text );
    }
    my $self = bless $node, $class;
    foreach my $d (@$dispatch) {
        eval "require $d" or die $@; ## no critic
        die "[$me] Skill plugin must support alexa_authenticate_token\n" unless $d->can('alexa_authenticate_token');
        die "[$me] Skill plugin must support alexa_configure\n" unless $d->can('alexa_configure');
        $config->{$d}->{'Amazon::Alexa::Dispatch'} = $self;
        my $h = $d->alexa_configure($config->{$d});
        die "[$me] Skill plugin must support alexa_configure\n" unless ref $h eq 'HASH' or ref $h eq $d;
        $self->{'token_dispatch'} = $h if ref $h eq $self->{'token_dispatch'};
        $d = {
            %$h,
            module => ref $h eq 'HASH' ? $d : $h,
        };
    }
    return $self;
}

sub _run_method {
    my $self = shift;
    my $json = shift;
    my $module;
    my $method = $json->{'request'}->{'intent'}->{'name'};
    my $resp;
    my $ok = eval {
        $module = $self->_find_module($method);
        1;
    };
    my $e = $@; # should only happen if they have a bad intent schema on amazon
    $resp = $self->_msg_to_hash('Sorry, I could not find that intent for this skill.',$e) if $e || !$ok || !$module;
    if (!$resp) {
        $ok = eval {
            $method = ($module->{'intentPrefix'}//'').$method;
            $self->_authenticate_token($module,$method,$json->{'session'}->{'user'}->{'accessToken'},$json->{'request'}->{'timestamp'});
        };
        $e = $@;
        $resp = $self->_msg_to_hash('Failed to authenticate.  Please use the Alexa mobile app to re link this skill.',$e) if $e || !$ok;


	my $easy_args = {}; # simplify pulling args out of the Amazon api
	if (ref $json->{'request'} eq 'HASH'
		&& exists $json->{'request'}->{'intent'}
		&& ref $json->{'request'}->{'intent'} eq 'HASH'
		&& exists $json->{'request'}->{'intent'}->{'slots'}
	) {
		foreach my $key (keys %{$json->{'request'}->{'intent'}->{'slots'}}) {
			$easy_args->{$key} = $json->{'request'}->{'intent'}->{'slots'}->{$key}->{'value'};
		}
	}
        $resp = $module->{'module'}->$method($easy_args,$json) unless $resp;
    }
    $self->_print_json($resp);
}

sub _find_module {
    my $self = shift;
    my $method = shift;
    foreach my $module (@{$self->{'dispatch'}}) {
        return $module if $module->{'module'}->can(($module->{'intentPrefix'}//'').$method);
    }
    die "[$me] Unknown intent $method\n" unless $self->{'dispatch'}->[0]->{'module'}->can($method);
}

sub _print_json {
    my $self = shift;
    my $data = shift;
    my $jsonp = JSON::XS->new;
    $jsonp->pretty(1);
    my $pretty_json = $jsonp->encode($self->_msg_to_hash($data));
    print "Content-Type:text/plain;charset=UTF-8\n\n",$pretty_json;
}

sub _msg_to_hash {
    my $self = shift;
    my $msg = shift;
    my $e = shift;
    warn $e if $e;
    return $msg if ref $msg eq 'HASH';
    return {
        version => '1.0',
        sessionAttributes=>{},
        response=>{
            outputSpeech => {
                type => 'PlainText',
                text => "$msg",
            },
            shouldEndSession => JSON::true,
        },
    };
}

sub _authenticate_token {
    my $self = shift;
    my $module = shift;
    my $method = shift;
    my $p = shift;
    my $t = shift || die "[$me] Missing request timestamp, try again later\n";
    $t =~ s/Z$/ +0000/;
    my $dateformat = '%Y-%m-%dT%H:%M:%S %z';
    my $date1 = eval{ Time::Piece->strptime($t, $dateformat)} || die "[$me] Invalid request timestamp, try again later\n";
    my $d_txt = `/bin/date +'$dateformat'`;
    chomp($d_txt);
    my $date2 = eval{ Time::Piece->strptime($d_txt, $dateformat) } || die "[$me] Could not read local time, try again later\n";
    die "[$me] Request too old, try again later\n" if abs($date1->strftime('%s') - $date2->strftime('%s')) > 500;
    $self->{'user'} = $module->{'module'}->alexa_authenticate_token($method,$p);
    die "[$me] Please open the Alexa $self->{'skillName'} skill to re link your account, then try again.\n" unless $self->{'user'};
    1;
}

=head2 dispatch_CGI

  Handles processing of calls in an apache or mod_perl environment.

  Can handle 3 types of calls
    1) Linking your Alexa skill
    2) Displaying a generic help page
    3) Processing an alexa skill request

=over

=over

=item helpPage

  Valid values are
    1) full - (default) displays a large help page.  Useful to for setting up your skill
    2) none - simply displays an empty HTML page.
    3) partial - (TODO) A simple blurb about your skill

  New users will likely want assistance with the "full" setting.  However once you have
  configured your alexa skill we recommend setting helpPage to "none" or "partial"

=back

=back

=cut

sub dispatch_CGI {
    my $self = shift;
    my $args = shift;
    $dispatch_type = 'CGI';
    require CGI;
    my $cgi = CGI->new;
    my $json_raw = $cgi->param('POSTDATA');
    if ($cgi->param('response_type') && $cgi->param('response_type') eq 'token'
        && $cgi->param('redirect_uri')
        && $cgi->param('state')
        && $cgi->param('client_id')
    ) {
        my $uri = $cgi->param('redirect_uri');
        my $state = $cgi->param('state');
        my $params = {$cgi->Vars};
        my $token = $self->{'token_dispatch'}->alexa_create_token( $params );
        if ($token) {
            my $full = $uri.'#token_type=Bearer&access_token='.uri_escape($token).'&state='.uri_escape($state);
            print &CGI::header(-'status'=>302,-'location'=>$full,-'charset'=>'UTF-8',-'Pragma'=>'no-cache',-'Expires'=>'-2d');
            print "Content-Type:text/html\n\nAlexa Link Created";
        } else {
            # no token was created.  hopefully they displayed some sort of login page as part of the alexa_create_token call
        }
    } elsif ($json_raw) {
        my $json_data= eval { decode_json($json_raw); };
        $self->_run_method($json_data);
    } elsif (($args->{'helpPage'}//'') eq 'none') {
        print "Content-Type:text/html\n\n";
    } else {
        print "Content-Type:text/html\n\n";
        if (!$self->{'token_dispatch'}->can('alexa_create_token')) {
            print '<font color=red>WARNING</font>: Your skill does not support auto-linking with alexa.  Missing "alexa_create_token" method.<br>';
        }
        print '<h1>Contents:</h1><ol>
<li><a href="#schema">Amazon Developer Login</a>
<li><a href="#schema">Intent Schema</a>
<li><a href="#slots">Custom Slot Types</a>
<li><a href="#utterances">Sample Utterances</a>
<li><a href="#intents">Intents</a>
<li><a href="?response_type=token&redirect_uri=fake&state=fake&client_id=fake">Alexa Link Page</a>
</ol>
You can configure your skill with the following data<br>';

        my $methodList = {};
        foreach my $module (@{$self->{'dispatch'}}) {
            my $m = quotemeta($module->{'intentPrefix'}//'');
            if ($m) {
                no strict 'refs'; ## no critic
                my $mname = ref $module->{'module'} // $module->{'module'};
                my @methods = grep { $_ =~ /^$m/ && $_ !~ /__meta$/ && $module->{'module'}->can($_) } sort keys %{$mname.'::'};
                use strict 'refs';
                foreach my $method (@methods) {
                    my $intent = $method;
                    my $meta = $method.'__meta';
                    $intent =~ s/^$m//;
                    $method = {method=>$method,intent=>$intent};
                    $method->{'meta'} = $module->{'module'}->$meta() if $module->{'module'}->can($meta);
                }
                $methodList->{$module->{'module'}} = \@methods;
            } else {
                $methodList->{$module->{'module'}} = [{errors=>"intentPrefix must exist to list methods"}];
            }
        }

        my $custom_slots = {};
        print '<a name="schema"><h1>Amazon Developer Login:</h1><a href="https://www.amazon.com/ap/signin">https://www.amazon.com/ap/signin</a>';
        print '<a name="schema"><h1>Intent Schema:</h1><textarea wrap=off cols=100 rows=10>{"intents": ['."\n";
        my $out = '';
        foreach my $m (sort keys %$methodList) {
            foreach my $i (@{$methodList->{$m}}) {
                tie(my %myhash, 'Tie::IxHash', 'intent' => $i->{'intent'}); # super annoying when the intent isn't first
                my $schema = \%myhash;

                if ($i->{'meta'}->{'slots'}) {
                    $schema->{'slots'} = clone $i->{'meta'}->{'slots'};
                    foreach my $slot (@{$schema->{'slots'}}) {
                        $custom_slots->{$slot->{'name'}} = $slot->{'values'};
                        delete $slot->{'values'}; # intent schema doesn't want this
                    }
                }
                $out .= &CGI::escapeHTML('    '.to_json($schema).",\n");
            }
        };
        chop($out);chop($out);
        print $out."\n  ]\n}</textarea><br>";

        print '<a name="slots"><h1>Custom Slot Types:</h1>';
        if (!scalar keys %$custom_slots) {
            print 'There are not custom slot types.';
        } else {
            print '<table cellpadding=3>';
            print '<tr><th></th><th>Type</th><th></th><th>Values</th></tr>';
            print "<script>function alexa_copy(id) {
                document.getElementById('copyarea').innerHTML = document.getElementById(id).innerHTML;
                document.getElementById('copyarea').style.display = '';
                document.getElementById('copyarea').select();
                document.execCommand('copy');
            }</script>";

            my $id;
            foreach my $name (sort keys %$custom_slots) {
                if (ref $custom_slots->{$name}) {
                    $id++;
                    my $n = 'copyarea'.$id;
                    print '<tr><td><a href="javascript:alexa_copy(\''.$n.'\');">Show</a></td>';
                    print '<td>'.&CGI::escapeHTML($name).'</td><td>-</td>';
                    my $v = join ' | ', @{$custom_slots->{$name}};
                    $v = substr($v,0,200).'...' if length $v > 200;
                    print '<td>'.&CGI::escapeHTML($v).'<textarea style="display:none" id='.$n.'>'
                        .&CGI::escapeHTML(join "\n", @{$custom_slots->{$name}}).'</textarea></td>';
                    print '</tr>';
                }
            }
            print '</table><textarea id=copyarea style="display:none" cols=100 rows=5></textarea>';
        }


        print '<a name="utterances"><h1>Sample Utternaces:</h1><textarea cols=100 rows=10>';
        foreach my $m (sort keys %$methodList) {
            foreach my $i (@{$methodList->{$m}}) {
                foreach my $u (@{$i->{'meta'}->{'utterances'}}) {
                    print &CGI::escapeHTML($i->{'intent'}.' '.$u)."\n";
                }
            }
        };
        print '</textarea><br>';

        print '<a name="intents"><h1>Intents:</h1>';
        foreach my $m (sort keys %$methodList) {
            foreach my $i (@{$methodList->{$m}}) {
                print '<h2>'.&CGI::escapeHTML($i->{'intent'}).'</h2>Interaction:<ul>';
                foreach my $u (@{$i->{'meta'}->{'utterances'}}) {
                    print '<li>Alexa tell '.&CGI::escapeHTML($self->{'skillName'}).' to '.$u;
                }
                print '</ul>';
            }
        };
    }
}

=head2 alexa_configure ( $config )

  All dispatch plugins should have this method.  It's used by the new plugin to configure
  the dispatcher.

=over

=item $config

  A hash containing config data meant for your plugin.  This can come from a config
  file, or be hard coded into your script.

  Plugins can define their own configuration needs.

=over

=item intentPrefix

  Recommended value is alexa_intent_, but anything can be used.

  This value will be prepended to all intent requests coming from Alexa.  For example
  if you have an intent called HelloIntent then the distpacher would look for a method
  similar to Amazon::Alexa::Plugin->alexa_intent_HelloIntent()

=back

=back

=cut

sub alexa_configure {
    my $class = shift;
    my $self = shift->{'Amazon::Alexa::Dispatch'};
    $self->{'intentPrefix'} = 'alexa_intent_';
    $self;
}

=head2 alexa_create_token ( $param )

  Should return nothing if no token was created.  Any other value will be assumed to
  be the token to send back to Amazon.

=over

=over

=item $param

  A hash containing the name/value pairs of all data submitted with the alexa skill request.

  Values provided by Amazon include
    response_type
    redirect_uri
    state
    client_id

  You can use any additional paramaters as needed.  So long as they do not conflict with the
  four amazon names above.

=back

=back

=cut

sub alexa_create_token {
    my ($self,$param) = @_;
    return 'fake' if ($param->{'Password'} && $param->{'Password'} eq 'fake');
    my $fields = {};
    $fields->{$_} = { type=>'hidden', value=> $param->{$_} } foreach keys %$param;
    $fields->{'Password'} = { type=>'password' };
    $self->alexa_login_helper( 'Fake Alexa Login','Please type "fake" into the password field.', $fields );
    return '';
}

=head2 alexa_login_helper ( $title, $blurb, $fields )

  A simple helper script to display a very trival login page to users who
  are linking the Alexa skill on their mobile device.

=over

=over

=item $title

  The title you wish to display at the top of the page.

=item $blurb

  A small paragraph or so of text to display below the title.

=item $fields

  A definition of field data to request from the user.

  Example

  $fields = {
     client_id => {
         type => 'hidden',
         value => '123',
     },
     my_password_key => {
         type => 'password',
         value => undef, # since the customer types this in themselves
     },
     ......
  };

=back

=back

=cut

sub alexa_login_helper {
    my $self = shift;
    $self->_alexa_login_helper_CGI(@_) if $dispatch_type eq 'CGI';
}

sub _alexa_login_helper_CGI {
    my ($self, $title, $blurb, $fields) = @_;
    print "Content-Type:text/html\n\n<html><head><title>".&CGI::escapeHTML($title)."</title></head><body>";
    print '<h1>'.&CGI::escapeHTML($title).'</h1>';
    print &CGI::escapeHTML($blurb).'<br><br><form><table>';
    foreach my $field (keys %$fields) {
        if ($fields->{$field}->{'type'} eq 'password') {
            print '<tr><td>'.&CGI::escapeHTML($field).'</td><td><input type=password name="'.&CGI::escapeHTML($field).'"></td></tr>';
        } elsif ($fields->{$field}->{'type'} eq 'hidden') {
            print '<input type=hidden name="'.&CGI::escapeHTML($field).'" value="'.&CGI::escapeHTML($fields->{$field}->{'value'}).'"></td></tr>';
        } else {
            print '<tr><td>x</td><td>x</td></tr>';
        }
    }
    print '<tr><td colspan=2 align=center><br><input type=submit></td></tr>';
    print '</form></table></body></html>';
}

=head2 alexa_authenticate_token( $method, $token )

  Used by the dispatcher to grant access.  Two arguments are passed in.

  If authentication is successful this method should return the "username" that is valid
  within your environment.

  If authentication fails, this method should die.

=over

=over

=item method

  This is the name of the action to be performed.  For example HelloIntent.

=item token

  The token provided by Amazon Alexa.

=back

=back

=cut

sub alexa_authenticate_token {
    my ($class, $method, $p) = @_;
    return 'nobody' if $p eq 'fake' && $method eq 'alexa_intent_HelloIntent';
    return '';
}

=head2 alexa_intent_HelloIntent( $args, $json )

  A sample intent action that an Alexa skill can perform.  All skills will be passed
  two values.

=over

=over

=item $args

  A simple hash containing all the "slot" data from Amazon.

=item $json

  Raw json data from Amazon.

=back

=back

  The return value should be the text that you wish Alexa to say in response to the
  skill request.

=cut

sub alexa_intent_HelloIntent {
    my ($class, $args, $json) = @_;
    return "Alexa dispatcher says hello\n";
}

=head2 alexa_intent_HelloIntent__meta

 Basic meta information about your skill.  This will be used by the automatic
 documentation to make it easier for others to create their own skills using your
 plugin

=cut

sub alexa_intent_HelloIntent__meta {
    return {
        utterances => [
            'hello',
        ],
        # slots => [{name=>"someName",type=>"AMAZON.NUMBER"},{name=>"anotherName",type=>"customName",values=>[1,2,3]}]
    }
}

1;
