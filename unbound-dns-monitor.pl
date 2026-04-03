#!/usr/bin/perl

#
# Copyright (C) Roman Dmitriev, rnd@rajven.ru
#

use utf8;
use warnings;
use Encode;
use open qw(:std :encoding(UTF-8));
no warnings 'utf8';

use English;
use base;
use FindBin '$Bin';
use strict;
use POSIX;
use File::Tail;
use Fcntl qw(:flock);
use Net::Patricia;
use Net::DNS;

# === LOGGING SETUP ===
my $DEBUG = 0;  # Set to 0 to disable debug messages
my $LOG_TIMESTAMP = 1;  # Add timestamps to log messages

my $IPSET = '/usr/sbin/ipset';

# === LOCKING AND INITIALIZATION ===

# Prevent multiple instances of the script
eval {
    open(SELF, "<", $0) or die "Cannot open $0 - $!";
    flock(SELF, LOCK_EX | LOCK_NB) or die "Another instance is already running";
};
if ($@) {
    log_error("Failed to acquire lock: $@");
    exit 1;
}
log_debug("Lock acquired successfully");

# Set low process priority (nice = 19)
eval {
    setpriority(0, 0, 19);
    log_debug("Process priority set to 19");
};
if ($@) {
    log_warning("Failed to set process priority: $@");
}

# === GLOBAL VARIABLES ===

# === IPSET CONFIG ===
my %ipsets = (
    'vpn'    => 'hash:ip',
    'direct' => 'hash:ip',
);

my $dns_resolver = '10.1.2.1';

my $ipset_dir = '/etc/ipset.d';

# Patricia tree for internal IPv4 cache (already added IPs)
my $dns_cache = new Net::Patricia;

# Patricia tree for RU_IPS ipset (Russian IP ranges)
my $ru_patricia = new Net::Patricia;

# Domain patterns with routing action - use single quotes for regex literals
my %search_domains = (
    # Local domains - direct routing
    '\.ru$'  => 'direct',
    '\.su$'  => 'direct',

    # TELEGRAM - vpn routing
    # Основной сайт
    '^telegram\.org$'  => 'vpn',
    '\.telegram\.org$' => 'vpn',
    # Короткие ссылки на профили и каналы
    '^t\.me$'  => 'vpn',
    '\.t\.me$' => 'vpn',
    # Хостинг медиафайлов и CDN
    '^telesco\.pe$'  => 'vpn',
    '\.telesco\.pe$' => 'vpn',
    # Альтернативный домен для ссылок
    '^telegram\.me$'  => 'vpn',
    '\.telegram\.me$' => 'vpn',
    # Платформа для публикации статей
    '^telegra\.ph$'  => 'vpn',
    '\.telegra\.ph$' => 'vpn',
    # CDN для контента Telegraph
    '^graph\.org$'  => 'vpn',
    '\.graph\.org$' => 'vpn',
    # Система комментариев
    '^comments\.app$'  => 'vpn',
    '\.comments\.app$' => 'vpn',
    # Домен для разработчиков
    '^tg\.dev$'  => 'vpn',
    '\.tg\.dev$' => 'vpn',
    # Бот-домен
    '^telegram\.dog$'  => 'vpn',
    '\.telegram\.dog$' => 'vpn',

    # WhatsApp - vpn routing
    # Основной сайт
    '^whatsapp\.com$'  => 'vpn',
    '\.whatsapp\.com$' => 'vpn',
    # Основная инфраструктура и сервисы
    '^whatsapp\.net$'  => 'vpn',
    '\.whatsapp\.net$' => 'vpn',
    # Короткие ссылки для чатов
    '^wa\.me$'  => 'vpn',
    '\.wa\.me$' => 'vpn',
    # Сокращение ссылок
    '^wl\.co$'  => 'vpn',
    '\.wl\.co$' => 'vpn',
    # Брендовые ресурсы
    '^whatsappbrand\.com$'  => 'vpn',
    '\.whatsappbrand\.com$' => 'vpn',
    # Веб-версия и медиа
    '^media\.whatsapp\.com$'  => 'vpn',
    '\.media\.whatsapp\.com$' => 'vpn',
    # Динамические edge-серверы
    '^dyn\.web\.whatsapp\.com$'  => 'vpn',
    '\.dyn\.web\.whatsapp\.com$' => 'vpn',

    # Facebook - vpn routing
    # Основная платформа
    '^facebook\.com$'  => 'vpn',
    '\.facebook\.com$' => 'vpn',
    # Короткие ссылки
    '^fb\.me$'  => 'vpn',
    '\.fb\.me$' => 'vpn',
    # Хостинг пользовательского контента
    '^fbsbx\.com$'  => 'vpn',
    '\.fbsbx\.com$' => 'vpn',
    # Отдельный домен для Messenger
    '^messenger\.com$'  => 'vpn',
    '\.messenger\.com$' => 'vpn',
    # Уведомления по почте
    '^facebookmail\.com$'  => 'vpn',
    '\.facebookmail\.com$' => 'vpn',
    # CDN для контента
    '^fbcdn\.net$'  => 'vpn',
    '\.fbcdn\.net$' => 'vpn',
    # Корпоративный сайт компании
    '^meta\.com$'  => 'vpn',
    '\.meta\.com$' => 'vpn',

    # Instagram - vpn routing
    # Основной сайт
    '^instagram\.com$'  => 'vpn',
    '\.instagram\.com$' => 'vpn',
    # CDN для изображений и видео
    '^cdninstagram\.com$'  => 'vpn',
    '\.cdninstagram\.com$' => 'vpn',
    # Короткие ссылки
    '^instagr\.am$'  => 'vpn',
    '\.instagr\.am$' => 'vpn',
    # Ссылки для прямого обмена сообщениями
    '^ig\.me$'  => 'vpn',
    '\.ig\.me$' => 'vpn',
    # Вспомогательный сервис
    '^igsonar\.com$'  => 'vpn',
    '\.igsonar\.com$' => 'vpn',

    # YouTube - direct routing
    # Основная платформа
    '^youtube\.com$'  => 'vpn',
    '\.youtube\.com$' => 'vpn',
    # Короткие ссылки на видео
    '^youtu\.be$'  => 'vpn',
    '\.youtu\.be$' => 'vpn',
    # Встраивание видео без отслеживания
    '^youtube-nocookie\.com$'  => 'vpn',
    '\.youtube-nocookie\.com$' => 'vpn',
    # Хостинг видеопотоков
    '^googlevideo\.com$'  => 'vpn',
    '\.googlevideo\.com$' => 'vpn',
    # CDN для превью и аватаров
    '^ytimg\.com$'  => 'vpn',
    '\.ytimg\.com$' => 'vpn',
    # Контент пользователей и CDN
    '^yt3\.googleusercontent\.com$'  => 'vpn',
    '\.yt3\.googleusercontent\.com$' => 'vpn',
    # Специализированные сервисы
    '^youtubeeducation\.com$'  => 'vpn',
    '\.youtubeeducation\.com$' => 'vpn',
    '^youtubekids\.com$'  => 'vpn',
    '\.youtubekids\.com$' => 'vpn',
    # API для разработчиков
    '^youtube\.googleapis\.com$'  => 'vpn',
    '\.youtube\.googleapis\.com$' => 'vpn',
);

sub log_message {
    my ($level, $message) = @_;
    my $timestamp = $LOG_TIMESTAMP ? strftime("%Y-%m-%d %H:%M:%S", localtime) . " " : "";
    print "${timestamp}[$level] $message\n";
}

sub log_debug {
    log_message("DEBUG", $_[0]) if $DEBUG;
}

sub log_info {
    log_message("INFO", $_[0]);
}

sub log_warning {
    log_message("WARNING", $_[0]);
}

sub log_error {
    log_message("ERROR", $_[0]);
}

# === LOAD RU_IPS IPSET INTO PATRICIA ===
sub load_ru_ipset {
    log_info("Loading RU_IPS ipset into Patricia tree...");
    
    # Check if RU_IPS ipset exists
    my $check = system("$IPSET list RU_IPS >/dev/null 2>&1");
    if ($check != 0) {
        log_warning("RU_IPS ipset does not exist, skipping load");
        return;
    }
    
    # Use ipset list and parse output
    my $list_cmd = "$IPSET list RU_IPS";
    open(my $fh, "-|", $list_cmd) or do {
        log_error("Cannot run '$list_cmd': $!");
        return;
    };
    
    my $count = 0;
    while (my $line = <$fh>) {
        chomp $line;
        # Lines with IP addresses look like: "192.168.1.1" or "192.168.0.0/16"
        if ($line =~ /^\s*(\d+\.\d+\.\d+\.\d+)(?:\/(\d+))?\s*$/) {
            my $ip = $1;
            my $mask = $2 // 32;
            my $cidr = "$ip/$mask";
            $ru_patricia->add_string($cidr);
            $count++;
            log_debug("Added $cidr to RU_IPS Patricia") if $DEBUG > 1;
        }
    }
    close $fh;
    log_info("Loaded $count networks from RU_IPS ipset");
}

# === IPSET INITIALIZATION ===
sub init_ipsets {
    log_info("Initializing ipsets...");

    # Создаём директорию для сохранения, если её нет
    if (!-d $ipset_dir) {
        eval {
            mkdir $ipset_dir or die "Cannot create $ipset_dir: $!";
            log_info("Created directory: $ipset_dir");
        };
        if ($@) {
            log_error("Failed to create directory $ipset_dir: $@");
            return;
        }
    }

    foreach my $set (keys %ipsets) {
        my $type = $ipsets{$set};
        my $file = "$ipset_dir/$set.conf";
        # Проверяем, существует ли уже ipset
        my $check = system("$IPSET list $set >/dev/null 2>&1");
        if ($check == 0) {
            log_info("ipset $set already exists, skipping restore/create");
            next;
        }
        # ipset не существует, пытаемся восстановить из файла
        if (-f $file) {
            log_info("Restoring ipset $set from $file...");
            my $result = system("$IPSET restore < $file 2>/dev/null");
            if ($result != 0) {
                log_warning("Failed to restore $set from $file, exit code: $result, will create new");
                # Создаём новый, если восстановление не удалось
                log_info("Creating ipset $set...");
                $result = system("$IPSET create $set $type comment 2>/dev/null");
                if ($result != 0) {
                    log_error("Failed to create ipset $set, exit code: $result");
                } else {
                    log_debug("Successfully created $set");
                }
            } else {
                log_debug("Successfully restored $set");
            }
        } else {
            # Файла нет, создаём новый ipset
            log_info("Creating ipset $set...");
            my $result = system("$IPSET create $set $type comment 2>/dev/null");
            if ($result != 0) {
                log_error("Failed to create ipset $set, exit code: $result");
            } else {
                log_debug("Successfully created $set");
            }
        }
    }
}

sub save_ipsets {
    log_info("Saving ipsets to $ipset_dir...");

    foreach my $set (keys %ipsets) {
        my $file = "$ipset_dir/$set.conf";
        my $tmp  = "$file.tmp";

        my $cmd = "$IPSET save $set > $tmp 2>/dev/null";
        my $res = system($cmd);

        if ($res == 0) {
            eval {
                rename $tmp, $file or die "Cannot rename $tmp to $file: $!";
                log_info("Saved $set to $file");
            };
            if ($@) {
                log_error("Failed to rename temp file for $set: $@");
            }
        } else {
            eval { unlink $tmp };
            log_error("Failed to save $set, exit code: $res");
        }
    }
}

# Initialize ipsets
eval {
    init_ipsets();
};
if ($@) {
    log_error("Failed to initialize ipsets: $@");
    exit 1;
}

# Load RU_IPS ipset into Patricia tree
load_ru_ipset();

# Signal handlers
$SIG{INT} = sub {
    log_info("Caught SIGINT, exiting...");
    eval { save_ipsets(); };
    if ($@) {
        log_error("Error during save on SIGINT: $@");
    }
    exit 0;
};

$SIG{TERM} = sub {
    log_info("Caught SIGTERM, exiting...");
    eval { save_ipsets(); };
    if ($@) {
        log_error("Error during save on SIGTERM: $@");
    }
    exit 0;
};

# Time to suppress duplicate events
my $mute_time = 3600;

# Log file path
my $log_file = '/var/log/unbound/unbound.log';

if (!-f $log_file) {
    log_warning("Log file $log_file does not exist yet, will wait for it");
}

# Track processed domains to avoid spam
my %processed_domains;

# Track IPs already added to ipset
my %ipset_added;

# DNS resolver instance
my $resolver = Net::DNS::Resolver->new(
    nameservers => [$dns_resolver],
    udp_timeout => 2,
    tcp_timeout => 2,
    retry       => 1,
    recurse     => 1,
);

log_info("Starting DNS monitor script");
log_debug("Debug mode is enabled");
log_debug("Mute time set to $mute_time seconds");
log_debug("Log file: $log_file");

# Main infinite log-processing loop
while (1) {
    eval {
        my $unbound_log = File::Tail->new(
            name               => $log_file,
            maxinterval        => 5,
            interval           => 1,
            ignore_nonexistent => 1,
        );
        
        if (!$unbound_log) {
            die "Failed to open $log_file: $!";
        }
        
        log_info("Successfully opened log file for monitoring");

        while (my $logline = $unbound_log->read) {
            next unless $logline;
            chomp($logline);
            
            log_debug("Processing log line: $logline") if $DEBUG > 1;

            if ($logline =~ /info:\s+[\d\.]+\s+([^\s]+)\.\s+A\s+IN\s*$/) {
                my $domain = lc($1);
                log_debug("Found A query for domain: $domain");

                if (exists $processed_domains{$domain}) {
                    my $time_since = time() - $processed_domains{$domain};
                    if ($time_since < $mute_time) {
                        log_debug("Skipping $domain (processed $time_since seconds ago, mute_time=$mute_time)");
                        next;
                    }
                }
                $processed_domains{$domain} = time();

                my $action = match_domain($domain);
                if (!$action) {
                    log_debug("No pattern match for domain: $domain");
                    next;
                }
                
                log_info("Domain $domain matched $action pattern, resolving...");

                my @ipv4_list = resolve_domain_ipv4($domain);
                if (!@ipv4_list) {
                    log_warning("No IPv4 addresses resolved for $domain");
                    next;
                }
                
                log_debug("Resolved " . scalar(@ipv4_list) . " IP(s) for $domain");

                foreach my $ip (@ipv4_list) {
                    add_ip_to_ipset($ip, $domain, $action);
                }
            }
        }
    };

    if ($@) {
        log_error("Critical error in main loop: $@");
        log_info("Waiting 60 seconds before restart...");
        sleep(60);
    }
}

exit;

# Check domain against regex patterns, return action or undef
sub match_domain {
    my ($domain) = @_;
    
    foreach my $pattern (keys %search_domains) {
        if ($domain =~ /$pattern/) {
            log_debug("Domain $domain matched pattern: $pattern");
            return $search_domains{$pattern};
        }
    }
    return undef;
}

# Resolve domain recursively, return list of unique IPv4 addresses
sub resolve_domain_ipv4 {
    my ($domain) = @_;
    my %seen_ips;
    my %visited;
    
    log_debug("Starting recursive resolution for $domain");
    my @results = _resolve_recursive($domain, \%seen_ips, \%visited);
    log_debug("Resolution for $domain returned " . scalar(@results) . " IP(s)");
    
    return @results;
}

# Recursive helper for CNAME/A resolution
sub _resolve_recursive {
    my ($name, $seen_ips_ref, $visited_ref) = @_;

    if (exists $visited_ref->{$name}) {
        log_debug("Prevented infinite loop at $name");
        return ();
    }
    $visited_ref->{$name} = 1;
    
    log_debug("Resolving: $name");
    
    my $query = eval { $resolver->search($name) };
    if (!$query || $@) {
        log_warning("DNS query failed for $name: " . ($@ || "unknown error"));
        return ();
    }

    my @results;

    foreach my $rr ($query->answer) {
        if ($rr->type eq 'A') {
            my $ip = $rr->address;
            if (exists $seen_ips_ref->{$ip}) {
                log_debug("Duplicate IP $ip for $name, skipping");
                next;
            }
            $seen_ips_ref->{$ip} = 1;
            push @results, $ip;
            log_debug("Found A record: $name -> $ip");
        }
        elsif ($rr->type eq 'CNAME') {
            my $cname = lc($rr->cname);
            log_debug("Following CNAME: $name -> $cname");
            push @results, _resolve_recursive($cname, $seen_ips_ref, $visited_ref);
        }
    }

    return @results;
}

# Add IP to Patricia cache and ipset if not already present
sub add_ip_to_ipset {
    my ($ip, $domain, $action) = @_;

    # Check Patricia cache first
    if ($dns_cache->match_string($ip)) {
        log_debug("IP $ip already in Patricia cache, skipping");
        return;
    }

    # Check local ipset tracker
    my $set_name = $action;
    if (exists $ipset_added{$ip} && $ipset_added{$ip} eq $set_name) {
        log_debug("IP $ip already tracked in $set_name, skipping");
        return;
    }

    # For direct action: skip if IP belongs to RU_IPS
    if ($action eq 'direct') {
        if ($ru_patricia->match_string($ip)) {
            log_debug("IP $ip is in RU_IPS range, skipping addition to direct set");
            return;
        }
    }

    # Add to Patricia cache
    $dns_cache->add_string($ip);

    # Prepare comment
    my $comment = prepare_comment($domain);

    # Execute ipset command
    my $cmd = sprintf(
        '%s add %s %s -exist comment "%s" 2>/dev/null',
        $IPSET,
        $set_name,
        $ip,
        $comment
    );

    my $result = system($cmd);
    if ($result == 0) {
        $ipset_added{$ip} = $set_name;
        log_info("Added $ip to $set_name (comment: $comment)");
    }
    else {
#        log_error("run: $cmd");
        log_error("Failed to add $ip to ipset, exit code: $result");
        $dns_cache->remove_string($ip);
    }
}

# Clean template for ipset comment
sub prepare_comment {
    my ($template) = @_;
    
    my $original = $template;
    
    $template =~ s/[\^\$]//g;
    $template =~ s/\\\.//g;
    $template =~ s/[\\\[\]\(\)\{\}\*\+\?\|]//g;
    
    log_debug("Comment prepared: '$original' -> '$template'") if $DEBUG > 1;
    
    return $template;
}
