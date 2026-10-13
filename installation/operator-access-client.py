"""Configure and verify pgAdmin's native libpq certificate service profiles."""
import argparse
import configparser
import datetime
import json
import os
from pathlib import Path
import sqlite3
import sys


def parameters(config, target):
    state = Path(config['state'])
    if target.get('authentication') == 'sspi':
        return dict(host=target['host'], hostaddr=target['hostaddr'], port=target['port'],
                    dbname=target['database'], user=config['role'], sslmode='verify-full',
                    sslrootcert=str(state / (target['ssh']+'-postgresql.crt')),
                    ssl_min_protocol_version='TLSv1.2', ssl_max_protocol_version='TLSv1.2',
                    sslcertmode='disable', require_auth='sspi', connect_timeout=10,
                    passfile=str(state / 'unused-no-password-file'))
    return dict(host=target['host'], hostaddr=target['hostaddr'], port=target['port'],
                dbname=target['database'], user=config['role'], sslmode='verify-full',
                sslrootcert=str(state / (target['ssh']+'-postgresql.crt')),
                sslcert=str(state / 'operator.crt'), sslkey='capi:'+config['certificate_subject'],
                ssl_min_protocol_version='TLSv1.2', ssl_max_protocol_version='TLSv1.2',
                sslcertmode='require', require_auth='none', connect_timeout=10,
                passfile=str(state / 'unused-no-password-file'))


def verify(config):
    import psycopg
    receipts=[]
    for target in config['targets']:
        params=parameters(config,target)
        with psycopg.connect(**params) as connection:
            row=connection.execute('SELECT current_user,current_database(),s.ssl,s.version,system_user,r.rolsuper '
                                   'FROM pg_stat_ssl s JOIN pg_roles r ON r.rolname=current_user '
                                   'WHERE s.pid=pg_backend_pid()').fetchone()
            expected=target.get('authentication_identity','cert:CN='+config['certificate_subject'])
            if row[0]!=config['role'] or row[4]!=expected or not row[5] or not row[2]:
                raise RuntimeError('The server did not authenticate the declared Windows operator')
            if not connection.execute('SELECT rolpassword IS NULL FROM pg_authid WHERE rolname=current_user').fetchone()[0]:
                raise RuntimeError('The certificate operator must have no database password')
        denials=[]
        probes = [('unmapped_role',dict(user='laplace_unmapped_operator_probe')),
                  ('wrong_server_identity',dict(host='laplace-wrong-host.invalid'))] if target.get('authentication') == 'sspi' else [
                             ('no_certificate',dict(sslcertmode='disable')),
                              ('wrong_windows_key',dict(sslkey='capi:laplace-nonexistent-operator')),
                              ('wrong_database_role',dict(user='postgres'))]
        for name, changes in probes:
            try:
                with psycopg.connect(**(params | changes)):
                    raise RuntimeError('Unexpected authentication: '+name)
            except psycopg.OperationalError:
                denials.append(name)
        receipts.append(dict(host=target['ssh'],role=row[0],database=row[1],tls=row[3],
                             certificate_subject=row[4],superuser=row[5],password_supplied=False,
                             denied=denials))
    return receipts


def install(config):
    state=Path(config['state'])
    database=Path(os.environ['APPDATA'])/'pgAdmin/pgadmin4.db'
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    services=state/'operator-services.conf'
    service_config=configparser.ConfigParser(interpolation=None)
    for target in config['targets']:
        service_config[target['service']]={k:str(v) for k,v in parameters(config,target).items()}
    with services.open('w',encoding='utf-8',newline='\n') as stream:
        service_config.write(stream,space_around_delimiters=False)
    # These supported pgAdmin settings scope OpenSSL and libpq configuration to this desktop app.
    local=Path(config['pgadmin'])/'web/config_local.py'
    original=local.read_text(encoding='utf-8') if local.exists() else ''
    marker='# BEGIN LAPLACE WINDOWS OPERATOR\n'
    ending='# END LAPLACE WINDOWS OPERATOR\n'
    if marker in original:
        before, managed=original.split(marker,1)
        _,after=managed.split(ending,1)
        original=before+after
    elif original:
        (state/('config_local-before-'+stamp+'.py')).write_text(original,encoding='utf-8')
    block=(marker+'import os as _laplace_operator_os\n'+
           '_laplace_operator_os.environ["OPENSSL_ENGINES"] = '+repr(str(Path(config['openssl'])/'lib/engines-3'))+'\n'+
           '_laplace_operator_os.environ["OPENSSL_CONF"] = '+repr(str(state/'operator-openssl.cnf'))+'\n'+
           '_laplace_operator_os.environ["PGSERVICEFILE"] = '+repr(str(services))+'\n'+ending)
    local.write_text(original.rstrip()+'\n'+block,encoding='utf-8')
    connection=sqlite3.connect(database)
    with sqlite3.connect(state/('pgadmin-before-certificate-'+stamp+'.db')) as backup:
        connection.backup(backup)
    try:
        connection.execute('BEGIN IMMEDIATE')
        for target in config['targets']:
            existing=connection.execute('SELECT name,user_id FROM server WHERE id=?',(target['server_id'],)).fetchone()
            if existing is None and target.get('authentication') == 'sspi':
                connection.execute('INSERT INTO server(id,user_id,servergroup_id,name) VALUES(?,1,1,?)',
                                   (target['server_id'],target['name']))
                existing=(target['name'],1)
            if existing != (target['name'],1):
                raise RuntimeError('The pgAdmin registration does not match the declared operator target')
            connection.execute('UPDATE server SET username=?,host=?,port=?,maintenance_db=?,service=?,password=NULL,'
                               'save_password=0,passexec_cmd=NULL,passexec_expiration=NULL,connection_params=?,kerberos_conn=0 '
                               'WHERE id=?',
                               (config['role'],target['host'],target['port'],target['database'],target['service'],
                                json.dumps({'connect_timeout':10,'hostaddr':target['hostaddr'],
                                            'sslmode':'verify-full'}),target['server_id']))
        connection.commit()
    except BaseException:
        connection.rollback()
        raise
    finally: connection.close()


def verify_pgadmin(config):
    sys.path.insert(0,str(Path(config['pgadmin'])/'web'))
    import config as pgadmin_config
    from pgadmin import create_app
    from pgadmin.model import User, Server
    from flask_login import login_user
    from pgadmin.utils.master_password import get_master_password_key_from_os_secret, set_crypt_key
    from pgadmin.utils.driver import get_driver
    app=create_app()
    app.PGADMIN_RUNTIME=True
    results=[]
    with app.test_request_context():
        login_user(User.query.filter_by(id=1).one())
        set_crypt_key(get_master_password_key_from_os_secret())
        driver=get_driver(pgadmin_config.PG_DEFAULT_DRIVER)
        for target in config['targets']:
            server=Server.query.filter_by(id=target['server_id']).one()
            if server.password or server.save_password or server.passexec_cmd:
                raise RuntimeError('The operator registration still contains password authentication')
            manager=driver.connection_manager(server.id)
            for database in target.get('databases', [target['database']]):
                connection=manager.connection(database=database)
                okay,error=connection.connect()
                if not okay: raise RuntimeError('pgAdmin connection failed: '+str(error))
                okay,result=connection.execute_dict('SELECT current_user,current_database(),system_user,ssl,version FROM pg_stat_ssl WHERE pid=pg_backend_pid()')
                if not okay: raise RuntimeError('pgAdmin identity query failed')
                row=result['rows'][0]
                expected=target.get('authentication_identity','cert:CN='+config['certificate_subject'])
                if row['current_user']!=config['role'] or row['system_user']!=expected or row['current_database']!=database or not row['ssl']:
                    raise RuntimeError('Unexpected pgAdmin authenticated identity, database or TLS state')
                results.append(dict(server=server.name,service=server.service,**row))
            manager.release()
    return results


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--configuration',required=True)
    parser.add_argument('--install',action='store_true')
    parser.add_argument('--pgadmin',action='store_true')
    args=parser.parse_args()
    config=json.loads(Path(args.configuration).read_text(encoding='utf-8-sig'))
    os.environ['OPENSSL_ENGINES']=str(Path(config['openssl'])/'lib/engines-3')
    os.environ['OPENSSL_CONF']=str(Path(config['state'])/'operator-openssl.cnf')
    os.environ.pop('PGPASSWORD',None)
    receipts=verify(config)
    if args.install: install(config)
    receipt=dict(verified_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                 windows_identity=config['windows_identity'],windows_sid=config['windows_sid'],
                 connections=receipts)
    if args.pgadmin: receipt['pgadmin']=verify_pgadmin(config)
    (Path(config['state'])/'certificate-verification.json').write_text(json.dumps(receipt,indent=2),encoding='utf-8')
    print(json.dumps(receipt,indent=2))


if __name__=='__main__': main()
