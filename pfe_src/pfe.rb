
require 'pg'
require 'fileutils'

@host = ARGF.argv[0] || 'localhost'
@database = ARGF.argv[1] || 'database'
@port = ARGF.argv[2] || '5432'
@user = ARGF.argv[3] || 'posgresql'
@action = ARGF.argv[4] || 'save'

@file = ARGF.argv[5].gsub(' ', '\\ ') unless ARGF.argv[5].nil?

def time
  start = Time.now
  yield
  puts "functions loaded\ntook #{(Time.now - start).round(4)} seconds"
end

def file_type(lang)
  case lang
  when '14' then 'sql'
  when '183355' then 'plperlu'
  else 'plpgsql'
  end
end

def volatile_type(volatile)
  case volatile
  when 's' then 'STABLE'
  when 'i' then 'IMMUTABLE'
  else 'VOLATILE'
  end
end

def test_connection(host, database, port, user)
  @connection = PGconn.open(dbname: database, host: host, port: port, user: user)
  rescue Exception => e
    puts "unable to connect\nto: #{database}\non: #{host}\nport: #{port}\n\nerror:\n\n#{e}"
end

def create_function_string(file)
  function = ''
  File.open(file, 'r') do |f|
    f.each_line do |line|
      function += line
    end
  end
  function
end

def save_function(host, database, port, user, file, use_std_out=true)
  @connection = test_connection(host, database, port, user)
  return @connection if @connection.is_a?(String)
  @function = create_function_string(file)

  result = @connection.exec(@function)
  if use_std_out
    puts result.cmd_status
  else
    return result.cmd_status
  end
  rescue Exception => e
    if use_std_out
      puts e
    else
      return e
    end
end

def run_single_test(connection, schema, test)
  function = "SELECT * FROM pgtap.runtests('#{schema}','#{test}'); "
  results = ''
  connection.set_notice_processor { |msg| results += "#{msg.to_s.split('CONTEXT:')[0]}" }
  connection.exec('BEGIN;')
  result = connection.exec(function)
  connection.exec('ROLLBACK;')
  result.each { |line| results += line['runtests'].to_s + "\n" }
  return results
  rescue Exception => e
    return e
end

def test_schema(connection, schema)
  function = "SELECT * FROM pgtap.runtests('#{schema}','^test'); "
  results = ''
  connection.set_notice_processor { |msg| results += "#{msg.to_s.split('CONTEXT:')[0]}" }
  connection.exec('BEGIN;')
  result = connection.exec(function)
  connection.exec('ROLLBACK;')
  result.each { |line| results += line['runtests'].to_s + "\n" }
  return results
  rescue Exception => e
    return e
end

case @action
when 'test'
  saved_function = save_function(@host, @database, @port, @user, @file, false)
  puts saved_function
  # return saved_function if saved_function.include? 'ERROR'

  @connection = test_connection(@host, @database, @port, @user)
  return @connection if @connection.is_a?(String)

  file = @file.split('/').pop(2)
  schema = file[0]
  test = file[1].split('.').first

  puts run_single_test(@connection, schema, test)
when 'test_schema'
  @connection = test_connection(@host, @database, @port, @user)
  return @connection if @connection.is_a?(String)

  file = @file.split('/').pop(2)
  schema = file[0]

  puts test_schema(@connection, schema)
when 'save'
 save_function(@host, @database, @port, @user, @file)

when 'create'
  time do
    tmp_dir = '/tmp/postgresFunctions/'

    FileUtils.rm_rf tmp_dir if Dir.exist? tmp_dir
    Dir.mkdir(tmp_dir, 0755)
    Dir.chdir(tmp_dir)

    @connection = test_connection(@host, @database, @port, @user)
    return @connection if @connection.is_a?(String)

    schemas = @connection.exec("SELECT schema_name FROM information_schema.schemata WHERE (schema_owner=$1 AND schema_name not in ('contrib','pgtap','pgagent')) OR schema_name='public';", [@user])
    @select = 'nspname as schema,provolatile as volatile, prosrc as body,
               proname as name,procost as cost,prolang as lang,
               pg_catalog.pg_get_function_arguments(p.oid) as args,
               pg_get_function_identity_arguments(p.oid) as drop_args,
               pg_catalog.pg_get_function_result(p.oid) as return_type'

    schemas.each { |schema| Dir.mkdir(schema['schema_name'], 0755) }

    schemas.each do |schema|
      functions = @connection.exec("SELECT #{@select} FROM pg_catalog.pg_proc p LEFT JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace WHERE  n.nspname ='#{schema['schema_name']}';")
      functions.each do |function|
        file_type = file_type(function['lang'])
        post_text = "$BODY$\nLANGUAGE '#{file_type}' #{volatile_type(function['volatile'])}\nCOST #{function['cost']};"
        Dir.chdir(tmp_dir + function['schema'])
        header = "-- DROP FUNCTION IF EXISTS  #{function['schema']}.#{function['name']}(#{function['drop_args']}) CASCADE;\n\n"
        IO.write(function['name'] + ".#{file_type}" , "#{header}CREATE OR REPLACE FUNCTION #{function['schema']}.#{function['name']}(#{function['args']})\nRETURNS #{function['return_type']} AS\n$BODY$" + function['body'] + post_text)
      end
    end
  end
end

