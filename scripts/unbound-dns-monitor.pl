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

# конфиг
my $CONFIG_FILE = '/etc/unbound-dns-monitor/unbound-dns-monitor.cfg';

# Читаем конфиг
my %config = read_bash_config($CONFIG_FILE);

# Используем переменные
# ipset path
my $IPSET = $config{'IPSET_CMD'} || '/usr/sbin/ipset';
# for work youtubeUnblocker
my $youtube_direct = $config{'YOUTUBE_DIRECT'} || 0;
# enabled hook?
my $hook_enabled = $config{'IPSET_HOOK_ENABLED'} || 0;
my $ipset_hook = $config{'IPSET_HOOK'} || '/usr/local/bin/ipset-hook.sh';
# Нормализуем youtube_direct (yes/no -> 1/0)
if ($youtube_direct =~ /^(yes|1|on|true)$/i) {
    $youtube_direct = 1;
} else {
    $youtube_direct = 0;
}
# нормализуем hook_enabled
if ($hook_enabled =~ /^(yes|1|on|true)$/i) {
    $hook_enabled = 1;
} else {
    $hook_enabled = 0;
}

my $dns_resolver = $config{'DNS_RESOLVER'} || '127.0.0.1';

my $ipset_dir = $config{'IPSET_CONF_DIR'} || '/etc/ipset.d';

my $RU_IPSET = $config{'RU_IPSET'} || 'RU_IPS';
my $YTB_ROUTES_IPSET = $config{'ROUTE_YOUTUBE_IPSET'} || 'route_youtube';

# === LOGGING SETUP ===

my $DEBUG = 0;
my $LOG_LEVEL = $config{'LOG_LEVEL'} || 'INFO';
if ($LOG_LEVEL eq 'DEBUG') { $DEBUG=1; }

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
    'direct' => 'hash:ip',
    'telegram' => 'hash:ip',
    'whatsapp' => 'hash:ip',
    'youtube' => 'hash:ip',
    'instagram' => 'hash:ip',
    'facebook' => 'hash:ip',
    'vpn'    => 'hash:ip',
);

my %ipsets_data;

# Domain patterns with routing action - use single quotes for regex literals
my %search_domains = (
    # Local domains - direct routing
    '\.ru$'  => 'direct',
    '\.su$'  => 'direct',

    # TELEGRAM - vpn routing
    # Основной сайт
    '^telegram\.org$'  => 'telegram',
    '\.telegram\.org$' => 'telegram',
    # Короткие ссылки на профили и каналы
    '^t\.me$'  => 'telegram',
    '\.t\.me$' => 'telegram',
    # Хостинг медиафайлов и CDN
    '^telesco\.pe$'  => 'telegram',
    '\.telesco\.pe$' => 'telegram',
    # Альтернативный домен для ссылок
    '^telegram\.me$'  => 'telegram',
    '\.telegram\.me$' => 'telegram',
    # Платформа для публикации статей
    '^telegra\.ph$'  => 'telegram',
    '\.telegra\.ph$' => 'telegram',
    # CDN для контента Telegraph
    '^graph\.org$'  => 'telegram',
    '\.graph\.org$' => 'telegram',
    # Система комментариев
    '^comments\.app$'  => 'telegram',
    '\.comments\.app$' => 'telegram',
    # Домен для разработчиков
    '^tg\.dev$'  => 'telegram',
    '\.tg\.dev$' => 'telegram',
    # Бот-домен
    '^telegram\.dog$'  => 'telegram',
    '\.telegram\.dog$' => 'telegram',

    # WhatsApp - vpn routing
    # Основной сайт
    '^whatsapp\.com$'  => 'whatsapp',
    '\.whatsapp\.com$' => 'whatsapp',
    # Основная инфраструктура и сервисы
    '^whatsapp\.net$'  => 'whatsapp',
    '\.whatsapp\.net$' => 'whatsapp',
    # Короткие ссылки для чатов
    '^wa\.me$'  => 'whatsapp',
    '\.wa\.me$' => 'whatsapp',
    # Сокращение ссылок
    '^wl\.co$'  => 'whatsapp',
    '\.wl\.co$' => 'whatsapp',
    # Брендовые ресурсы
    '^whatsappbrand\.com$'  => 'whatsapp',
    '\.whatsappbrand\.com$' => 'whatsapp',
    # Веб-версия и медиа
    '^media\.whatsapp\.com$'  => 'whatsapp',
    '\.media\.whatsapp\.com$' => 'whatsapp',
    # Динамические edge-серверы
    '^dyn\.web\.whatsapp\.com$'  => 'whatsapp',
    '\.dyn\.web\.whatsapp\.com$' => 'whatsapp',

    # Facebook - vpn routing
    # Основная платформа
    '^facebook\.com$'  => 'facebook',
    '\.facebook\.com$' => 'facebook',
    # Короткие ссылки
    '^fb\.me$'  => 'facebook',
    '\.fb\.me$' => 'facebook',
    # Хостинг пользовательского контента
    '^fbsbx\.com$'  => 'facebook',
    '\.fbsbx\.com$' => 'facebook',
    # Отдельный домен для Messenger
    '^messenger\.com$'  => 'facebook',
    '\.messenger\.com$' => 'facebook',
    # Уведомления по почте
    '^facebookmail\.com$'  => 'facebook',
    '\.facebookmail\.com$' => 'facebook',
    # CDN для контента
    '^fbcdn\.net$'  => 'facebook',
    '\.fbcdn\.net$' => 'facebook',
    # Корпоративный сайт компании
    '^meta\.com$'  => 'facebook',
    '\.meta\.com$' => 'facebook',

    # Instagram - vpn routing
    # Основной сайт
    '^instagram\.com$'  => 'instagram',
    '\.instagram\.com$' => 'instagram',
    # CDN для изображений и видео
    '^cdninstagram\.com$'  => 'instagram',
    '\.cdninstagram\.com$' => 'instagram',
    # Короткие ссылки
    '^instagr\.am$'  => 'instagram',
    '\.instagr\.am$' => 'instagram',
    # Ссылки для прямого обмена сообщениями
    '^ig\.me$'  => 'instagram',
    '\.ig\.me$' => 'instagram',
    # Вспомогательный сервис
    '^igsonar\.com$'  => 'instagram',
    '\.igsonar\.com$' => 'instagram',

    # YouTube - direct routing by route_youtube ipset
    # Основная платформа
    '^youtube\.com$'  => 'youtube',
    '\.youtube\.com$' => 'youtube',
    # Короткие ссылки на видео
    '^youtu\.be$'  => 'youtube',
    '\.youtu\.be$' => 'youtube',
    # Встраивание видео без отслеживания
    '^youtube-nocookie\.com$'  => 'youtube',
    '\.youtube-nocookie\.com$' => 'youtube',
    # Хостинг видеопотоков
    '^googlevideo\.com$'  => 'youtube',
    '\.googlevideo\.com$' => 'youtube',
    # CDN для превью и аватаров
    '^ytimg\.com$'  => 'youtube',
    '\.ytimg\.com$' => 'youtube',
    # Контент пользователей и CDN
    '^yt3\.googleusercontent\.com$'  => 'youtube',
    '\.yt3\.googleusercontent\.com$' => 'youtube',
    # Специализированные сервисы
    '^youtubeeducation\.com$'  => 'youtube',
    '\.youtubeeducation\.com$' => 'youtube',
    '^youtubekids\.com$'  => 'youtube',
    '\.youtubekids\.com$' => 'youtube',
    # API для разработчиков
    '^youtube\.googleapis\.com$'  => 'youtube',
    '\.youtube\.googleapis\.com$' => 'youtube',
    # youtubei.googleapis.com
    '^youtubei\.googleapis\.com$'  => 'youtube',
    '^\.youtubei\.googleapis\.com$'  => 'youtube',
);


# Initialize ipsets
eval {
    init_ipsets();
};
if ($@) {
    log_error("Failed to initialize ipsets: $@");
    exit 1;
}

# Patricia tree for internal IPv4 cache (already added IPs)
my $dns_cache = new Net::Patricia;

# Patricia tree for RU_IPS ipset (Russian IP ranges)
my $ru_patricia = new Net::Patricia;
my $route_youtube= new Net::Patricia;

# Load RU_IPS ipset into Patricia tree
load_ipset_data($RU_IPSET,$ru_patricia);
load_ipset_data($YTB_ROUTES_IPSET,$route_youtube) if ($youtube_direct);

foreach my $ipset_name (keys %ipsets) {
    $ipsets_data{$ipset_name} = new Net::Patricia;
    load_ipset_data($ipset_name,$ipsets_data{$ipset_name});
}

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

    # Add to Patricia cache
    $dns_cache->add_string($ip);

    # For direct action: skip if IP belongs to RU_IPS
    if ($action eq 'direct') {
        if ($ru_patricia->match_string($ip)) {
            log_debug("IP $ip is in $RU_IPSET range, skipping addition to direct set");
            return;
        }
    }

    # For youtube action: skip if IP belongs to route_youtube
    if ($action eq 'youtube' && $youtube_direct && $route_youtube) {
        if ($route_youtube->match_string($ip)) {
            log_debug("IP $ip is in custom $YTB_ROUTES_IPSET range, skipping addition to youtube set");
            return;
        }
    }

    # Check exists in loaded ipset data
    if ($ipsets_data{$action}->match_string($ip)) {
        log_debug("IP $ip already in $action ipset, skipping addition to set");
        return;
    }

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
    log_debug("IPSET run: $cmd");
    if ($result == 0) {
        $ipset_added{$ip} = $set_name;
        log_info("Added $ip to $set_name (comment: $comment)");
        $ipsets_data{$action}->add_string($ip,$comment);
        if ($hook_enabled && -e $ipset_hook) {
            $cmd = "$ipset_hook $set_name $ip $comment >/dev/null 2>&1 &";
            log_debug("Hook run: $cmd");
            system($cmd);
            }
    }
    else {
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

sub log_message {
    my ($level, $message) = @_;
    print "[$level] $message\n";
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

# === LOAD IPSET INTO PATRICIA ===
sub load_ipset_data {
    my $ipset_name = shift;
    my $patricia_ref = shift;

    log_info("Loading ipset $ipset_name into Patricia tree...");

    # Check if ipset exists
    my $check = system("$IPSET list $ipset_name >/dev/null 2>&1");
    if ($check != 0) {
        log_warning("$ipset_name ipset does not exist, try create...");
        # Determine ipset type based on naming convention
        my $ipset_type = "hash:ip";
        if ($ipset_name eq $RU_IPSET) {
                # Strict match for RU_IPS
                $ipset_type = "hash:net";
                log_debug("$RU_IPSET detected, using hash:net type");
            }
            elsif ($ipset_name =~ /^route_/) {
                # Everything starting with 'route_'
                $ipset_type = "hash:net";
                log_debug("$ipset_name starts with 'route_', using hash:net type");
                }
                else { log_debug("$ipset_name using default hash:ip type"); }
        $check = system("$IPSET create $ipset_name $ipset_type family inet hashsize 1024 maxelem 2655360 comment");
        if ($check != 0) {
            log_warning("$ipset_name ipset does not exist and create failed, skipping load");
            return;
        }
        log_info("ipset $ipset_name created.");
    }

    # Use ipset list and parse output
    my $list_cmd = "$IPSET list $ipset_name";
    open(my $fh, "-|", $list_cmd) or do {
        log_error("Cannot run '$list_cmd': $!");
        return;
    };

    my $count = 0;
    while (my $line = <$fh>) {
        chomp $line;
        my $comment = '';
        # Format: IP[/mask] [comment "text"]
        # Examples: 
        #   192.168.1.1
        #   149.154.175.209 comment "pluto-1.web.telegram.org"
        #   10.0.0.0/24 comment "internal network"
        if ($line =~ /^\s*(\d+\.\d+\.\d+\.\d+)(?:\/(\d+))?\s+(?:comment\s+)?(?:"([^"]*)"|(\S+))?\s*$/) {
            my $ip = $1;
            my $mask = $2 // 32;
            my $cidr = "$ip/$mask";
            my $comment_text = $3 // $4 // '';
            $comment_text =~ s/^"|"$//g;
            if ($comment_text) {
                $patricia_ref->add_string($cidr, \$comment_text);
            } else {
                $patricia_ref->add_string($cidr);
            }
            $count++;
            log_debug("Added $cidr to $ipset_name Patricia") if $DEBUG > 1;
        } else {
            # Handle lines without optional parts
            if ($line =~ /^\s*(\d+\.\d+\.\d+\.\d+)(?:\/(\d+))?\s*$/) {
                my $ip = $1;
                my $mask = $2 // 32;
                my $cidr = "$ip/$mask";
                $patricia_ref->add_string($cidr);
                $count++;
                log_debug("Added $cidr to $ipset_name Patricia") if $DEBUG > 1;
            }
        }
    }
    close $fh;
    log_info("Loaded $count networks from $ipset_name ipset");
}

sub read_bash_config {
    my ($file) = @_;
    my %config;
    open(my $fh, '<', $file) or die "Cannot open $file: $!";
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*#/;
        next if $line =~ /^\s*$/;
        # Ищем переменные вида NAME="value" или NAME=value
        if ($line =~ /^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$/) {
            my $name = $1;
            my $value = $2;
            # Убираем кавычки
            $value =~ s/^["']//;
            $value =~ s/["']$//;
            # Обрабатываем массивы вида (item1 item2 ...)
            if ($value =~ /^\((.*)\)$/) {
                my @items = split(/\s+/, $1);
                $config{$name} = \@items;
            } else {
                $config{$name} = $value;
            }
        }
    }
    close($fh);
    return %config;
}
