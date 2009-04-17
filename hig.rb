#!/usr/bin/env ruby
=begin

# hig.rb

this scripts need net-irc ( http://svn.coderepos.org/share/lang/ruby/net-irc )

## Launch

	$ ruby hig.rb

If you want to help:

	$ ruby hig.rb --help

## Configuration

Options specified by after irc realname.

Configuration example for Tiarra ( http://coderepos.org/share/wiki/Tiarra ).

	wassr {
		host: localhost
		port: 16672
		name: hatena-id
		in-encoding: utf8
		out-encoding: utf8
	}

### athack

If `athack` client option specified,
all nick in join message is leading with @.

So if you complemente nicks (e.g. Irssi),
it's good for Twitter like reply command (@nick).

In this case, you will see torrent of join messages after connected,
because NAMES list can't send @ leading nick (it interpreted op.)

### ratio=<timeline>:<friends>:<channel>

## License

yappo

base code by cho45 (wig.rb)

=end

$LOAD_PATH << "lib"
$LOAD_PATH << "../lib"

$KCODE = "u" # json use this

require "rubygems"
require "net/irc"
require "net/http"
require "uri"
require "json"
require "socket"
require "time"
require "logger"
require "yaml"
require "pathname"
require "cgi"
require "digest/md5"

Net::HTTP.version_1_2

class HatenaIrcGateway < Net::IRC::Server::Session
	def server_name
		"hatettergw"
	end

	def server_version
		"0.0.0"
	end

	def main_channel
		"#hatena"
	end

	def api_base
		URI("http://hatetter.blogdb.jp/")
	end

	def api_source
		"hig.rb"
	end

	def hourly_limit
		150
	end

	class ApiFailed < StandardError; end

	def initialize(*args)
		super
		@user_agent = "#{self.class}/#{server_version} (hig.rb)"
	end

	def on_user(m)
		super
		post @prefix, JOIN, main_channel
		post server_name, MODE, main_channel, "+o", @prefix.nick

		@real, *@opts = @opts.name || @real.split(/\s+/)
		@opts = @opts.inject({}) {|r,i|
			key, value = i.split("=")
			r.update(key => value)
		}

		log "Client Options: #{@opts.inspect}"
		@log.info "Client Options: #{@opts.inspect}"

		@ratio  = Struct.new(:timeline, :friends, :channel).new(*(@opts["ratio"] || "10:3:5").split(":").map {|ratio| ratio.to_f })
		@footing = @ratio.inject {|r,i| r + i }

		@timeline = []

		@check_timeline_thread = Thread.start do
			sleep 3
			loop do
				begin
					check_timeline
					# check_direct_messages
				rescue ApiFailed => e
					@log.error e.inspect
				rescue Exception => e
					@log.error e.inspect
					e.backtrace.each do |l|
						@log.error "\t#{l}"
					end
				end
				sleep freq(@ratio[:timeline] / @footing)
			end
		end
	end

	def on_disconnected
		@check_timeline_thread.kill rescue nil
	end

	private
	def check_timeline
		@prev_time ||= Time.at(0)
		hatena_id = @real || @nick
		api("#{hatena_id}/statuses/friends_timeline").reverse_each do |s|
			id = s["id"]
			next if id.nil? || @timeline.include?(id)
			@timeline << id
			nick = s["user_login_id"]
			mesg = generate_status_message(s)

			@log.debug [id, nick, mesg]
			if nick == @nick # 自分のときは topic に
				post "#{nick}!#{nick}@#{api_base.host}", TOPIC, main_channel, untinyurl(mesg)
			else
				message(nick, main_channel, mesg)
			end
		end
		@log.debug "@timeline.size = #{@timeline.size}"
		@timeline  = @timeline.last(200)
		@prev_time = Time.now
	end

	def generate_status_message(status)
		s = status
		mesg = s["text"]
		@log.debug(mesg)

		# time = Time.parse(s["created_at"]) rescue Time.now
		m = { "&quot;" => "\"", "&lt;"=> "<", "&gt;"=> ">", "&amp;"=> "&", "\n" => " "}
		mesg.gsub!(/(#{m.keys.join("|")})/) { m[$1] }
		mesg
	end

	def freq(ratio)
		ret = 3600 / (hourly_limit * ratio).round
		@log.debug "Frequency: #{ret}"
		ret
	end

	def api(path, q={})
		ret           = {}
		q["source"] ||= api_source

		uri = api_base.dup
		uri.path  = "/#{path}.json"
		uri.query = q.inject([]) {|r,(k,v)| v ? r << "#{k}=#{URI.escape(v, /[^-.!~*'()\w]/n)}" : r }.join("&")


		req = Net::HTTP::Get.new(uri.request_uri)
		req["User-Agent"]        = @user_agent
		req["If-Modified-Since"] = q["since"] if q.key?("since")

		@log.debug uri.inspect
		ret = Net::HTTP.start(uri.host, uri.port) { |http| http.request(req) }

		case ret
		when Net::HTTPOK # 200
			ret = JSON.parse(ret.body.gsub(/'(y(?:es)?|no?|true|false|null)'/, '"\1"'))
			raise ApiFailed, "Server Returned Error: #{ret["error"]}" if ret.kind_of?(Hash) && ret["error"]
			ret
		when Net::HTTPNotModified # 304
			[]
		when Net::HTTPBadRequest # 400
			# exceeded the rate limitation
			raise ApiFailed, "#{ret.code}: #{ret.message}"
		else
			raise ApiFailed, "Server Returned #{ret.code} #{ret.message}"
		end
	rescue Errno::ETIMEDOUT, JSON::ParserError, IOError, Timeout::Error, Errno::ECONNRESET => e
		raise ApiFailed, e.inspect
	end

	def message(sender, target, str)
		str    = untinyurl(str)
		sender = "#{sender}!#{sender}@#{api_base.host}"
		post sender, PRIVMSG, target, str
	end

	def log(str)
		str.gsub!(/\n/, " ")
		post server_name, NOTICE, main_channel, str
	end

	def untinyurl(text)
		text.gsub(%r|http://(preview\.)?tinyurl\.com/[0-9a-z=]+|i) {|m|
			uri = URI(m)
			uri.host = uri.host.sub($1, "") if $1
			Net::HTTP.start(uri.host, uri.port) {|http|
				http.open_timeout = 3
				begin
					http.head(uri.request_uri, { "User-Agent" => @user_agent })["Location"] || m
				rescue Timeout::Error
					m
				end
			}
		}
	end

end

if __FILE__ == $0
	require "optparse"

	opts = {
		:port  => 16672,
		:host  => "localhost",
		:log   => nil,
		:debug => false,
		:foreground => false,
	}

	OptionParser.new do |parser|
		parser.instance_eval do
			self.banner = <<-EOB.gsub(/^\t+/, "")
				Usage: #{$0} [opts]

			EOB

			separator ""

			separator "Options:"
			on("-p", "--port [PORT=#{opts[:port]}]", "port number to listen") do |port|
				opts[:port] = port
			end

			on("-h", "--host [HOST=#{opts[:host]}]", "host name or IP address to listen") do |host|
				opts[:host] = host
			end

			on("-l", "--log LOG", "log file") do |log|
				opts[:log] = log
			end

			on("--debug", "Enable debug mode") do |debug|
				opts[:log]   = $stdout
				opts[:debug] = true
			end

			on("-f", "--foreground", "run foreground") do |foreground|
				opts[:log]        = $stdout
				opts[:foreground] = true
			end

			on("-n", "--name [user name or email address]") do |name|
				opts[:name] = name
			end

			parse!(ARGV)
		end
	end

	opts[:logger] = Logger.new(opts[:log], "daily")
	opts[:logger].level = opts[:debug] ? Logger::DEBUG : Logger::INFO

#	def daemonize(foreground=false)
#		trap("SIGINT")  { exit! 0 }
#		trap("SIGTERM") { exit! 0 }
#		trap("SIGHUP")  { exit! 0 }
#		return yield if $DEBUG || foreground
#		Process.fork do
#			Process.setsid
#			Dir.chdir "/"
#			File.open("/dev/null") {|f|
#				STDIN.reopen  f
#				STDOUT.reopen f
#				STDERR.reopen f
#			}
#			yield
#		end
#		exit! 0
#	end

#	daemonize(opts[:debug] || opts[:foreground]) do
		Net::IRC::Server.new(opts[:host], opts[:port], HatenaIrcGateway, opts).start
#	end
end

# Local Variables:
# coding: utf-8
# End:
