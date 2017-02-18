package Amazon::Alexa::Dispatch;
use strict;
use warnings;
use JSON;
use Net::OAuth2;
use Time::Piece;
use URI::Escape;

my $me = 'Amazon::Alexa::Dispatch';

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
  A Perl module which provides a simple and lightweight interface to the Alexa Skills Kit.

=cut

sub new {
    my $class = shift;
    my $args = shift;
    my $dispatch = $args->{'dispatch'};
    $dispatch = [$dispatch] if $dispatch && !ref $dispatch;
    push @$dispatch, 'Amazon::Alexa::Dispatch';
    my $node = {
        skillName => $args->{'skillName'} // 'SKILL',
    dispatch => $dispatch,
        token_dispatch => $args->{'token_dispatch'} || $dispatch->[0],
    };
    foreach my $d (@$dispatch) {
        eval "require $d"; ## no critic
        die "[$me] Skill plugin must support alexa_authenticate_token\n" unless $d->can('alexa_authenticate_token');
        die "[$me] Skill plugin must support alexa_configure\n" unless $d->can('alexa_configure');
        my $h = $d->alexa_configure;
        die "[$me] Skill plugin must support alexa_configure\n" unless ref $h eq 'HASH';
        $d = {
            %$h,
            module => $d,
        };
    }
    return bless $node, $class;
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
        $resp = $module->{'module'}->$method($self->{'user'},$json) unless $resp;
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

sub dispatch_CGI {
    my $self = shift;
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
        my $token = $self->{'token_dispatch'}->alexa_create_token();
        if ($token) {
            my $full = $uri.'#token_type=Bearer&access_token='.uri_escape($token).'&state='.uri_escape($state);
            print &CGI::header(-'status'=>302,-'location'=>$full,-'charset'=>'UTF-8',-'Pragma'=>'no-cache',-'Expires'=>'-2d');
        } else {
            # should never get here if the alexa_create_token was built properly.
            print "Content-Type:text/html\n\n";
            print "Something went wrong.  Please try to link the skill again\n";
        }
    } elsif ($json_raw) {
        my $json_data= eval { decode_json($json_raw); };
        $self->_run_method($json_data);
    } else {
        print "Content-Type:text/html\n\n";
        print 'You can configure your skill with the following data<br><br>';
        if (!$self->{'token_dispatch'}->can('alexa_create_token')) {
            print '<font color=red>WARNING</font>: Your skill does not support auto-linking with alexa.  Missing "alexa_create_token" method.<br>';
        }
        print '
<h1>Contents:</h1><ol>
<li><a href="#schema">Intent Schema</a>
<li><a href="#utterances">Sample Utterances</a>
<li><a href="#intents">Intents</a>
</ol>
';

        my $methodList = {};
        foreach my $module (@{$self->{'dispatch'}}) {
            my $m = quotemeta($module->{'intentPrefix'}//'');
            if ($m) {
                no strict 'refs'; ## no critic
                my @methods = grep { $_ =~ /^$m/ && $_ !~ /__meta$/ && $module->{'module'}->can($_) } sort keys %{$module->{'module'}.'::'};
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

        print '<a name="schema"><h1>Intent Schema:</h1><textarea cols=100 rows=10>{"intents": ['."\n";
        my $out = '';
        foreach my $m (sort keys %$methodList) {
            foreach my $i (@{$methodList->{$m}}) {
                my $schema = {intent=>$i->{'intent'}};
                $schema->{'slots'} = $i->{'meta'}->{'slots'} if $i->{'meta'}->{'slots'};
                $out .= &CGI::escapeHTML('    '.to_json($schema).",\n");
            }
        };
        chop($out);chop($out);
        print $out."  ]\n}</textarea><br>";

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
use Data::Dumper;
print '<pre>';
print $self->{'skillName'};
print Dumper $methodList;
    }
}

sub alexa_configure {{
    intentPrefix => 'alexa_intent_',
    skillName => 'Dispatcher',
}}

sub alexa_create_token {
    die "[$me] Not supported\n";
}

sub alexa_authenticate_token {
    return 'nobody';
}

sub alexa_intent_HelloIntent__meta { {
    utterances => [
        'hello',
    ],
    # slots => [{name=>"someName",type=>"someType"},{name=>"anotherName",type=>"anotherType"}]
} }

sub alexa_intent_HelloIntent {
    return "Alexa dispatcher says hello\n";
}


1;
__END__
