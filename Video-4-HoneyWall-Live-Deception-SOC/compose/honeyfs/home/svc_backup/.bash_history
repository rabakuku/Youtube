cd /opt/backup
ls -la
mysqldump -u backup_ro -p corp_crm > /opt/backup/db_dump.sql
gzip -k db_dump.sql
vi ~/passwords.txt
sudo cat /root/.aws/credentials
aws s3 ls s3://corp-prod-backups --profile prod-backup
exit
