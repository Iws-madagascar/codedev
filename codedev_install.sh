#!/bin/bash

####################################################################
#### Code-Server install Script for Oracle Linux, Centos/Redhat ####
#### and Ubuntu Servers.                                        ####
#### Author: Phil Connor 02/10/2020                             ####
#### Contact: contact@mylinux.work                              ####
#### Version 1.30                                               ####
####                                                            ####
#### To use this script chmod it to 755                         ####
#### or simply type bash <filename.sh>                          ####  
####################################################################

#############################
#### User Configurations ####
#############################
CODEDIR=/code # Home directory for your Code 
EMAIL=admin@mydomain.com # your domain email address
HTTPTYPE=APACHE # Choose Apache, Caddy or Nginx All UPPER Case
PASSWD=pAsSwOrD # Your Password for Code-server used for Apache, Nginx and Caddy
UNAME=MyUser # Username Used for Caddy
SERVDIR=/usr/local/code-server # where you want the code-server installed
SERVERNAME=code.mydomain.cloud # server fqdn name
USRDIR=/var/lib/code-server

########################
#### System Configs ####
########################
CADPASS="$(echo -e "${PASSWD}\n$PASSWD" | caddy hash-password 2>/dev/null | tail --lines=1)"
OS=$(grep PRETTY_NAME /etc/os-release | sed 's/PRETTY_NAME=//g' | tr -d '="' | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
OSVER=$(grep VERSION_ID /etc/os-release | sed 's/VERSION_ID=//g' | tr -d '="' | awk -F. '{print $1}')

define() {
	IFS=$'\n' read -r -d '' "$1"
	}

###########################################################
#### Detect Package Manger from OS and OSVer Variables ####
###########################################################
if [ "${OS}" = ubuntu ]; then
	PAKMGR="apt-get -y"
elif [[ ${OS} = centos || ${OS} = redhat || ${OS} = oracle || ${OS} = rocky || ${OS} = alma ]]; then
	if [ "${OSVER}" = 7 ]; then
		PAKMGR="yum -y"
	fi
	if [[ ${OSVER} = 8 || ${OSVER} = 9 ]]; then
	PAKMGR="dnf -y"
	fi
fi

################################
#### Check if OS is Updated ####
################################
if [ "${OS}" = ubuntu ]; then
    ${PAKMGR} upgrade
    ${PAKMGR} install libc6 libstdc++6
else
	${PAKMGR} update
fi

###############################################
#### Get the latest version of Code Server ####
###############################################
get_latest_version() {
	{
	version="$(curl -fsSLI -o /dev/null -w "%{url_effective}" https://github.com/coder/code-server/releases/latest)"
	version="${version#https://github.com/coder/code-server/releases/tag/}"
	version="${version#v}"
	echo "$version"
	}
}

#########################################
#### Download and Install Codeserver ####
#########################################
install_codeserver() {
	{
	# check if command wget exists
    if ! command -v wget >/dev/null 2>&1; then 
		${PAKMGR} install wget
    fi
	cd ~/ || exit
	wget "https://github.com/coder/code-server/releases/download/v$version/code-server-$version-linux-amd64.tar.gz"
	tar xvf "code-server-$version-linux-amd64.tar.gz"
	mkdir ${CODEDIR}
	mkdir ${SERVDIR}
	cp -r ~/code-server-"$version"-linux-amd64/* ${SERVDIR}
	ln -s ${SERVDIR}/bin/code-server /usr/bin/code-server
	# Code Directory
	mkdir "${CODEDIR}"
	# User Directory
	mkdir "${USRDIR}"

	csserv=/lib/systemd/system
	touch $csserv/code-server.service
	OUTFILE1="$csserv/code-server.service"
	define SFILE << EOF
	[Unit]
	Description=code-server
	After=nginx.service

	[Service]
	Type=simple
	Environment=PASSWORD=$PASSWD
	ExecStart=/usr/bin/code-server --bind-addr 127.0.0.1:8080 --user-data-dir ${USRDIR} --auth password
	Restart=always

	[Install]
	WantedBy=multi-user.target
EOF

	{
		printf "%s\n" "$SFILE" | cut -c 2-
	} > "$OUTFILE1"

	if [ $HTTPTYPE = CADDY ]; then
		sed -i 's/After=nginx.service/After=caddy.service/g' $csserv/code-server.service
		sed -i 's/auth: password/auth: none' /root/.config/code-server/config.yaml
		sed -i "ExecStart=/usr/bin/code-server --bind-addr 127.0.0.1:8080 --user-data-dir ${CODEDIR} --auth password/ExecStart=/usr/bin/code-server --bind-addr 127.0.0.1:8080 --user-data-dir ${CODEDIR}" $csserv/code-server.service
	fi
	
	systemctl daemon-reload
	systemctl start code-server
	systemctl enable code-server
	}
}

########################################
#### Install Apache, Nginx or Caddy ####
########################################
install_http() {
	{
	if [ $HTTPTYPE = APACHE ]; then
        csserv=/lib/systemd/system
        sed -i 's/After=nginx.service/After=apache.service/g' $csserv/code-server.service
        if [[ ${OS} = centos || ${OS} = redhat || ${OS} = oracle || ${OS} = rocky || ${OS} = alma ]]; then
            if ! command -v httpd &> /dev/null; then
				${PAKMGR} install httpd
                systemctl enable --now httpd
            fi
			AOUTFILE="/etc/httpd/conf.d/code-server.conf"
        elif [ "${OS}" = ubuntu ]; then
			if ! command -v apache2 &> /dev/null; then
                ${PAKMGR} install apache2
                systemctl enable --now apache2
            fi
			AOUTFILE="/etc/httpd/sites-available/code-server.conf"
        fi
            define ACONF << 'EOF'
            <VirtualHost *:80>
                ServerName $SERVERNAME
                #ProxyPreserveHost On
                RewriteEngine On
                RewriteCond %{HTTP:Upgrade} =websocket [NC]
                RewriteRule /(.*)           ws://127.0.0.1:8080/$1 [P,L]
                RewriteCond %{HTTP:Upgrade} !=websocket [NC]
                RewriteRule /(.*)           http://127.0.0.1:8080/$1 [P,L]
                ProxyRequests off
                #RequestHeader set X-Forwarded-Proto https
                #RequestHeader set X-Forwarded-Port 443
                ProxyPass / http://127.0.0.1:8080/ nocanon
                ProxyPassReverse / http://127.0.0.1:8080/
            </VirtualHost>
EOF
		{
			printf "%s\n" "$ACONF" | cut -c 4-
		} > "$AOUTFILE"
        
		systemctl daemon-reload
        systemctl restart code-server
        systemctl restart httpd
	fi

	if [ $HTTPTYPE = NGINX ]; then
		if [[ ${OS} = centos || ${OS} = redhat || ${OS} = oracle || ${OS} = rocky || ${OS} = alma ]]; then
			OUTFILE="/etc/yum.repos.d/nginx.repo"
			define NYUM << 'EOF'
			[nginx-stable]
			name=nginx stable repo
			baseurl=http://nginx.org/packages/centos/$releasever/$basearch/
			gpgcheck=1
			enabled=1
			gpgkey=https://nginx.org/keys/nginx_signing.key
			module_hotfixes=true
EOF
			{
				printf "%s\n" "$NYUM" | cut -c 4-
				} > "$OUTFILE"
			if [ "${OSVER}" = 8  ] || [ "${OSVER}" = 9  ]; then
				# shellcheck disable=2016
				sed -i 's/baseurl=http:\/\/nginx.org\/packages\/centos\/7\/$basearch\//baseurl=http:\/\/nginx.org\/packages\/centos\/8\/$basearch\//g' $OUTFILE
			fi
		fi
		
		if [ "${OS}" = ubuntu ]; then
			${PAKMGR} install curl gnupg2 ca-certificates lsb-release
			echo "deb http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" | sudo tee /etc/apt/sources.list.d/nginx.list
			echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" | sudo tee /etc/apt/preferences.d/99nginx
			curl -o /tmp/nginx_signing.key https://nginx.org/keys/nginx_signing.key
			if [ "$OSVER" = 16 ]; then
				gpg --with-fingerprint /tmp/nginx_signing.key			
			else
				gpg --dry-run --quiet --import --import-options show-only /tmp/nginx_signing.key
			fi
			sudo mv /tmp/nginx_signing.key /etc/apt/trusted.gpg.d/nginx_signing.asc
			sudo apt update
		fi
			
		${PAKMGR} install nginx

		if [[ ${OS} = centos || ${OS} = redhat || ${OS} = oracle || ${OS} = rocky || ${OS} = alma ]]; then 
			nxdir=/etc/nginx/conf.d		
		elif [ "${OS}" = ubuntu ]; then
			if [ "$OSVER" = 16 ]; then 
				nxdir=/etc/nginx/sites-available
			else 
				nxdir=/etc/nginx/conf.d	
			fi
		fi
		
		OUTFILE2="$nxdir/code-server.conf"
		define NFIG << EOF
		server {
			listen 80;
			listen [::]:80;
			server_name $SERVERNAME;
			location / {
				proxy_pass http://localhost:8080/;
				proxy_set_header Host \$host;
				proxy_set_header Upgrade \$http_upgrade;
				proxy_set_header Connection upgrade;
				proxy_set_header Accept-Encoding gzip;
			}
		}
EOF
		{
			printf "%s\n" "$NFIG" | cut -c 2-
			} > "$OUTFILE2"

		if [ "${OS}" = ubuntu ]; then 
			mv $nxdir/default $nxdir/default.orig
			ln -s $nxdir/code-server.conf $nxdir/code-server.conf
		else
			mv $nxdir/default.conf $nxdir/default.conf.orig
		fi
		systemctl start nginx
		systemctl enable nginx
	fi

	if [ "$HTTPTYPE" = CADDY ]; then
		if [ "${OS}" = ubuntu ]; then
			${PAKMGR} debian-keyring debian-archive-keyring apt-transport-https
			curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/cfg/gpg/gpg.155B6D79CA56EA34.key' | apt-key add -
			curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/cfg/setup/config.deb.txt?distro=debian&version=any-version' | tee -a /etc/apt/sources.list.d/caddy-stable.list
			${PAKMGR} update
			${PAKMGR} install caddy
		elif [[ ${OS} = centos || ${OS} = redhat || ${OS} = oracle || ${OS} = rocky || ${OS} = alma ]]; then
				if [ "${OSVER}" = 7 ]; then
					${PAKMGR} install yum-plugin-copr
				elif [ "${OSVER}" = 8  ] || [ "${OSVER}" = 9  ]; then
					${PAKMGR} install 'dnf-command(copr)'
				fi
				${PAKMGR} copr enable @caddy/caddy
				${PAKMGR} install caddy
		fi

	caddir=/etc/caddy
	mv $caddir/Caddyfile $caddir/Caddyfile.orig
	touch $caddir/Caddyfile
	OUTFILE3="$caddir/Caddyfile"
	define CFILE << EOF
	{                                                                  #### Remove these 3 lines
        acme_ca https://acme-staging-v02.api.letsencrypt.org/directory #### to make server live 
        }                                                              #### and grab cert from letsencrypt

	$SERVERNAME {
        basicauth /* {
            $UNAME  $CADPASS
        }
		reverse_proxy 127.0.0.1:8080
	}

EOF
	{
		printf "%s\n" "$CFILE" | cut -c 2-
		} > "$OUTFILE3"
	
	systemctl enable caddy
	systemctl start caddy
	
	fi
	
	}
}

##########################################
#### Install Certbot and request Cert ####
##########################################
install_certbot() {
	{
	if [ $HTTPTYPE = NGINX ];then
		if [ "${OS}" = ubuntu ]; then
			${PAKMGR} remove letsencrypt
			${PAKMGR} remove certbot
			snap install core; snap refresh core
			snap install --classic certbot
			${PAKMGR} install python3-certbot-nginx
		elif [[ ${OS} = centos || ${OS} = redhat || ${OS} = oracle || ${OS} = rocky || ${OS} = alma ]]; then 
			${PAKMGR} remove certbot
			${PAKMGR} install epel-release
			${PAKMGR} install snapd	
			if [ "$OSVER" = 7 ]; then
				${PAKMGR} install python2-certbot-nginx
			elif [ "${OSVER}" = 8  ] || [ "${OSVER}" = 9  ]; then
				${PAKMGR} install python3-certbot-nginx
			fi
        fi
    fi
    if [ $HTTPTYPE = APACHE ];then
        if [ "${OS}" = ubuntu ]; then
            ${PAKMGR} remove letsencrypt
            ${PAKMGR} remove certbot
            snap install core; snap refresh core
            snap install --classic certbot
            ${PAKMGR} install python3-certbot-apache
        elif [[ ${OS} = centos || ${OS} = redhat || ${OS} = oracle || ${OS} = rocky || ${OS} = alma ]]; then 
            ${PAKMGR} remove certbot
            ${PAKMGR} install epel-release
            ${PAKMGR} install snapd	
            if [ "$OSVER" = 7 ]; then
                ${PAKMGR} install python2-certbot-apache
            elif [ "${OSVER}" = 8  ] || [ "${OSVER}" = 9  ]; then
                ${PAKMGR} install python3-certbot-apache
            fi
        fi
    fi
	systemctl enable --now snapd.socket
    ln -s /var/lib/snapd/snap /snap
	snap install core; snap refresh core
    snap install --classic certbot
    ln -s /snap/bin/certbot /usr/bin/certbot
    
	#certbot certonly --redirect --agree-tos --nginx -d $SERVERNAME -m "$EMAIL" --dry-run
	certbot --non-interactive --redirect --agree-tos --nginx -d $SERVERNAME -m "$EMAIL" 
	systemctl restart nginx
    if [ $HTTPTYPE = NGINX ]; then 
        if [[ ${OS} = centos || ${OS} = redhat || ${OS} = oracle || ${OS} = rocky || ${OS} = alma ]]; then
            if ! grep "certbot" /var/spool/cron/root; then
                echo "0 */12 * * * root certbot -q renew --nginx" >> /var/spool/cron/root
            fi
        elif [ "${OS}" = ubuntu ]; then
            if ! grep "certbot" /var/spool/cron/crontabs/root; then	
                echo "0 */12 * * * root certbot -q renew --nginx" >> /var/spool/cron/crontabs/root
            fi
        fi
	elif [ $HTTPTYPE = APACHE ]; then 
        if [[ ${OS} = centos || ${OS} = redhat || ${OS} = oracle || ${OS} = rocky || ${OS} = alma ]]; then
            if ! grep "certbot" /var/spool/cron/root; then
                echo "0 */12 * * * root certbot -q renew --apache" >> /var/spool/cron/root
            fi
        elif [ "${OS}" = ubuntu ]; then
            if ! grep "certbot" /var/spool/cron/crontabs/root; then	
                echo "0 */12 * * * root certbot -q renew --apache" >> /var/spool/cron/crontabs/root
            fi
        fi
    fi

	grep nginx /var/log/audit/audit.log | audit2allow -M nginx
	semodule -i nginx.pp
	}
}

function install_firewall() {
	{
	if [[ ${OS} = centos || ${OS} = redhat || ${OS} = oracle || ${OS} = rocky || ${OS} = alma ]]; then	
		${PAKMGR} install ipset perl-libwww-perl.noarch perl-LWP-Protocol-https.noarch perl-GDGraph perl-Sys-Syslog perl-Math-BigInt
	elif [ "${OS}" = ubuntu ]; then
		${PAKMGR} install ipset libwww-perl liblwp-protocol-https-perl libgd-graph-perl
	fi
	cd /usr/src || exit
	# rm -fv csf.tgz
	wget https://download.configserver.com/csf.tgz
	tar -xzf csf.tgz
	cd csf || exit
	./install.sh
	echo ''
	echo '###########################################'
	echo '#### Testing if CSF firewall will work ####'
	echo '###########################################'
	echo ''
	perl /usr/local/csf/bin/csftest.pl		
	##### Initial Settings #####
	sed -i 's/TESTING = "1"/TESTING = "0"/g' /etc/csf/csf.conf
	sed -i 's/RESTRICT_SYSLOG = "0"/RESTRICT_SYSLOG = "3"/g' /etc/csf/csf.conf
	sed -i '/^RESTRICT_UI/c\RESTRICT_UI = "1"' /etc/csf/csf.conf
	sed -i '/^AUTO_UPDATES/c\AUTO_UPDATES = "1"' /etc/csf/csf.conf
	##### IPv4 Port Settings #####
	sed -i 's/TCP_IN = "20,21,22,25,53,80,110,143,443,465,587,993,995"/TCP_IN = "22,80,443,5666,10000"/g' /etc/csf/csf.conf
	sed -i 's/TCP_OUT = "20,21,22,25,53,80,110,113,443,587,993,995"/TCP_OUT = "22,25,53,80,443,5666,10000"/g' /etc/csf/csf.conf
	sed -i 's/UDP_IN = "20,21,53,80,443"/UDP_IN = "80,443"/g' /etc/csf/csf.conf
	sed -i 's/UDP_OUT = "20,21,53,113,123"/UDP_OUT = "53,113,123"/g' /etc/csf/csf.conf
	sed -i '/^ICMP_IN_RATE/c\ICMP_IN_RATE = "1/s"' /etc/csf/csf.conf
	##### IPv6 Port Settings #####
	sed -i 's/IPV6 = "0"/IPV6 = "1"/g' /etc/csf/csf.conf
	sed -i 's/TCP6_IN = "20,21,22,25,53,80,110,143,443,465,587,993,995"/TCP6_IN = "22,80,443,5666"/g' /etc/csf/csf.conf
	sed -i 's/TCP6_OUT = "20,21,22,25,53,80,110,113,443,587,993,995"/TCP6_OUT = "22,80,443,5666"/g' /etc/csf/csf.conf
	sed -i 's/UDP6_IN = "20,21,53,80,443"/UDP6_IN = "80,443"/g' /etc/csf/csf.conf
	sed -i 's/UDP6_OUT = "20,21,53,113,123"/UDP6_OUT = "53,113,123"/g' /etc/csf/csf.conf
	##### General Settings #####
	sed -i 's/SYSLOG_CHECK = "0"/SYSLOG_CHECK = "300"/g' /etc/csf/csf.conf
	sed -i '/^IGNORE_ALLOW/c\IGNORE_ALLOW = "0"' /etc/csf/csf.conf
	sed -i '/^LF_CSF/c\LF_CSF = "1"' /etc/csf/csf.conf
	sed -i 's/LF_IPSET = "0"/LF_IPSET = "1"/g' /etc/csf/csf.conf
	sed -i '/^PACKET_FILTER/c\PACKET_FILTER = "1"' /etc/csf/csf.conf
	##### SMTP Settings #####
	sed -i 's/SMTP_BLOCK = "0"/SMTP_BLOCK = "1"/g' /etc/csf/csf.conf
	##### Port Flood Settings #####
	sed -i 's/SYNFLOOD = "0"/SYNFLOOD = "1"/g' /etc/csf/csf.conf
	sed -i 's/CONNLIMIT = ""/CONNLIMIT= "22;5,25;3,80;10"/g' /etc/csf/csf.conf
	sed -i 's/PORTFLOOD = ""/PORTFLOOD = "22;tcp;5;300,25;tcp;5;300,80;tcp;20;5"/g' /etc/csf/csf.conf
	sed -i 's/UDPFLOOD = "0"/UDPFLOOD = "1"/g' /etc/csf/csf.conf
	##### Logging Settings #####
	sed -i 's/SYSLOG = "0"/SYSLOG = "1"/g' /etc/csf/csf.conf
	sed -i '/^DROP_LOGGING/c\DROP_LOGGING = "1"' /etc/csf/csf.conf
	sed -i '/^DROP_ONLYRES/c\DROP_ONLYRES = "0"' /etc/csf/csf.conf
	sed -i '/^UDPFLOOD_LOGGING/c\UDPFLOOD_LOGGING = "1"' /etc/csf/csf.conf 
	##### Temp to Perm/Netblock Settings #####
	sed -i '/^LF_PERMBLOCK^/c\LF_PERMBLOCK = "1"' /etc/csf/csf.conf
	sed -i 's/LF_NETBLOCK = "0"/LF_NETBLOCK = "1"/g' /etc/csf/csf.conf
	##### Login Failure Blocking and Alerts #####
	sed -i 's/LF_SSHD = "5"/LF_SSHD = "3"/g' /etc/csf/csf.conf
	sed -i 's/LF_FTPD = "10"/LF_FTPD = "5"/g' /etc/csf/csf.conf
	sed -i 's/LF_SMTPAUTH = "0"/LF_SMTPAUTH = "5"/g' /etc/csf/csf.conf
	sed -i 's/LF_EXIMSYNTAX = "0"/LF_EXIMSYNTAX = "10"/g' /etc/csf/csf.conf
	sed -i 's/LF_POP3D = "0"/LF_POP3D = "5"/g' /etc/csf/csf.conf
	sed -i 's/LF_IMAPD = "0"/LF_IMAPD = "5"/g' /etc/csf/csf.conf
	sed -i 's/LF_HTACCESS = "0"/LF_HTACCESS = "5"/g' /etc/csf/csf.conf
	sed -i 's/LF_MODSEC = "5"/LF_MODSEC = "3"/g' /etc/csf/csf.conf
	sed -i 's/LF_CXS = "0"/LF_CXS = "1"/g' /etc/csf/csf.conf
	sed -i 's/LF_SYMLINK = "0"/LF_SYMLINK = "5"/g' /etc/csf/csf.conf
	sed -i 's/LF_WEBMIN = "0"/LF_WEBMIN = "3"/g' /etc/csf/csf.conf
	sed -i '/^LF_SSH_EMAIL_ALERT/c\LF_SSH_EMAIL_ALERT = "1"' /etc/csf/csf.conf
	sed -i '/^LF_SU_EMAIL_ALERT/c\LF_SU_EMAIL_ALERT = "1"' /etc/csf/csf.conf
	sed -i '/^LF_SUDO_EMAIL_ALERT/c\LF_SUDO_EMAIL_ALERT = "1"' /etc/csf/csf.conf
	sed -i '/^LF_WEBMIN_EMAIL_ALERT/c\LF_WEBMIN_EMAIL_ALERT = "1"' /etc/csf/csf.conf
	sed -i '/^LF_CONSOLE_EMAIL_ALERT/c\LF_CONSOLE_EMAIL_ALERT = "1"' /etc/csf/csf.conf
	sed -i '/^LF_BLOCKINONLY/c\LF_BLOCKINONLY = "0"' /etc/csf/csf.conf
	##### Directory Watching & Integrity #####
	sed -i '/^LF_DIRWATCH^/c\LF_DIRWATCH = "300"' /etc/csf/csf.conf
	sed -i '/^LF_INTEGRITY/c\LF_INTEGRITY = "3600"' /etc/csf/csf.conf
	##### Distributed Attacks #####
	sed -i 's/LF_DISTATTACK = "0"/LF_DISTATTACK = "1"/g' /etc/csf/csf.conf
	sed -i 's/LF_DISTFTP = "0"/LF_DISTFTP = "5"/g' /etc/csf/csf.conf
	sed -i 's/LF_DISTSMTP = "0"/LF_DISTSMTP = "5"/g' /etc/csf/csf.conf
	##### Connection Tracking #####
	sed -i 's/CT_LIMIT = "0"/CT_LIMIT = "300"/g' /etc/csf/csf.conf
	##### Process Tracking #####
	sed -i '/^PT_LIMIT/c\PT_LIMIT = "60"' /etc/csf/csf.conf
	sed -i '/^PT_SKIP_HTTP/c\PT_SKIP_HTTP = "0"' /etc/csf/csf.conf
	sed -i 's/PT_DELETED = "0"/PT_DELETED = "1"/g' /etc/csf/csf.conf
	sed -i 's/PT_USERTIME = "1800"/PT_USERTIME = "0"/g' /etc/csf/csf.conf
	sed -i 's/PT_FORKBOMB = "0"/PT_FORKBOMB = "250"/g' /etc/csf/csf.conf
	##### Port Scan Tracking #####
	sed -i 's/PS_INTERVAL = "0"/PS_INTERVAL = "300"/g' /etc/csf/csf.conf
	sed -i '/^PS_EMAIL_ALERT/c\PS_EMAIL_ALERT = "1"' /etc/csf/csf.conf
	##### User ID Tracking #####
	sed -i 's/UID_INTERVAL = "0"/UID_INTERVAL = "600"/g' /etc/csf/csf.conf
	##### Account Tracking #####
	sed -i 's/AT_ALERT = "2"/AT_ALERT = "1"/g' /etc/csf/csf.conf
	systemctl enable --now csf
	systemctl enable --now lfd
	}
}

function install_webmin() {
	{
	if [[ ${OS} = centos || ${OS} = redhat || ${OS} = oracle || ${OS} = rocky || ${OS} = alma ]]; then
		OUTFILE="/etc/yum.repos.d/webmin.repo"
		define WYUM << 'EOF'
		[Webmin]
		name=Webmin Distribution Neutral
		#baseurl=https://download.webmin.com/download/yum
		mirrorlist=https://download.webmin.com/download/yum/mirrorlist
		enabled=1
EOF
		{
			printf "%s\n" "$WYUM" | cut -c 3-
			} > "$OUTFILE"
	wget https://download.webmin.com/jcameron-key.asc
	rpm --import jcameron-key.asc
		if [ "${OSVER}" = 7 ]; then
			${PAKMGR} install perl-Encode-Detect perl-Net-SSLeay perl-Data-Dumper tcp_wrappers-devel perl-IO-Tty webmin unzip
		elif [ "${OSVER}" = 8  ] || [ "${OSVER}" = 9 ]; then
			${PAKMGR} install perl-Encode-Detect perl-Net-SSLeay perl-Data-Dumper tcp_wrappers tcp_wrappers-libs unzip 
			dnf config-manager --set-enabled powertools
			${PAKMGR} install perl-IO-Tty webmin
		fi
	elif [ "${OS}" = ubuntu ]; then  
		{
		echo ''
		echo '############################'
		echo '#### Adding Webmin Repo ####'
		echo '############################'
		echo ''
		echo 'deb https://download.webmin.com/download/repository sarge contrib'
		} >> /etc/apt/sources.list
		wget https://download.webmin.com/jcameron-key.asc
		apt-key add jcameron-key.asc
		${PAKMGR} install apt-transport-https
		${PAKMGR} update
		${PAKMGR} install webmin
	fi
	}
}
get_latest_version
install_codeserver
install_http
install_certbot
install_firewall
install_webmin
