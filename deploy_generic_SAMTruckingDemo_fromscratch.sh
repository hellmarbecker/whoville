#!/usr/bin/env bash
# Launch Centos 7 Vm with at least 4 cores / 14Gb mem / 20Gb disk
# Then run:
# curl -sSL https://raw.githubusercontent.com/harshn08/whoville/master/deploy_generic_SAMTruckingDemo_fromscratch.sh | sudo -E bash


export ambari_version=2.5.1.0
export mpack_url=http://public-repo-1.hortonworks.com/HDF/centos6/3.x/updates/3.0.1.1/tars/hdf_ambari_mp/hdf-ambari-mpack-3.0.1.1-5.tar.gz
#export mpack_url=http://public-repo-1.hortonworks.com/HDF/centos7/3.x/updates/3.0.0.0/tars/hdf_ambari_mp/hdf-ambari-mpack-3.0.0.0-453.tar.gz
export ambari_password=${ambari_password:-StrongPassword}
export db_password=${db_password:-StrongPassword}
export nifi_flow="https://gist.githubusercontent.com/abajwa-hw/3857a205d739473bb541490f6471cdba/raw"
#export nifi_flow="https://gist.githubusercontent.com/abajwa-hw/a78634099c82cd2bab1ccceb8cc2b86e/raw"
export install_solr=true    ## for Twitter demo
export host=$(hostname -f)

export ambari_services="AMBARI_METRICS HDFS MAPREDUCE2 YARN ZOOKEEPER DRUID STREAMLINE NIFI KAFKA STORM REGISTRY HBASE PHOENIX ZEPPELIN"
export cluster_name=Whoville
export ambari_stack_version=2.6
export host_count=1
#service user for Ambari to setup demos
export service_user="demokitadmin"
export service_password="BadPass#1"


#echo Patching...
#yum update -y
#echo Host Setup...
# The following should really be a systemd service
#sudo yum install -y wget
#sudo wget -nv http://public-repo-1.hortonworks.com/ambari/centos7/2.x/updates/2.5.1.0/ambari.repo -O /etc/yum.repos.d/ambari.repo
#sudo yum repolist
echo Installing Packages...
sudo yum localinstall -y https://dev.mysql.com/get/mysql57-community-release-el7-8.noarch.rpm
sudo yum install -y git python-argparse epel-release mysql-connector-java* mysql-community-server
# MySQL Setup to keep the new services separate from the originals
echo Database setup...
sudo systemctl enable mysqld.service
sudo systemctl start mysqld.service
#extract system generated Mysql password
oldpass=$( grep 'temporary.*root@localhost' /var/log/mysqld.log | tail -n 1 | sed 's/.*root@localhost: //' )
#create sql file that
# 1. reset Mysql password to temp value and create druid/superset/registry/streamline schemas and users
# 2. sets passwords for druid/superset/registry/streamline users to ${db_password}
cat << EOF > mysql-setup.sql
ALTER USER 'root'@'localhost' IDENTIFIED BY 'Secur1ty!'; 
uninstall plugin validate_password;
CREATE DATABASE druid DEFAULT CHARACTER SET utf8; CREATE DATABASE superset DEFAULT CHARACTER SET utf8; CREATE DATABASE registry DEFAULT CHARACTER SET utf8; CREATE DATABASE streamline DEFAULT CHARACTER SET utf8; 
CREATE USER 'druid'@'%' IDENTIFIED BY '${db_password}'; CREATE USER 'superset'@'%' IDENTIFIED BY '${db_password}'; CREATE USER 'registry'@'%' IDENTIFIED BY '${db_password}'; CREATE USER 'streamline'@'%' IDENTIFIED BY '${db_password}'; 
GRANT ALL PRIVILEGES ON *.* TO 'druid'@'%' WITH GRANT OPTION; GRANT ALL PRIVILEGES ON *.* TO 'superset'@'%' WITH GRANT OPTION; GRANT ALL PRIVILEGES ON registry.* TO 'registry'@'%' WITH GRANT OPTION ; GRANT ALL PRIVILEGES ON streamline.* TO 'streamline'@'%' WITH GRANT OPTION ; 
commit; 
EOF
#execute sql file
mysql -h localhost -u root -p"$oldpass" --connect-expired-password < mysql-setup.sql
#change Mysql password to ${db_password}
mysqladmin -u root -p'Secur1ty!' password ${db_password}
#test password and confirm dbs created
mysql -u root -p${db_password} -e 'show databases;'
# Install Ambari251
echo Installing Ambari

export install_ambari_server=true
#export java_provider=oracle
curl -sSL https://raw.githubusercontent.com/abajwa-hw/ambari-bootstrap/master/ambari-bootstrap.sh | sudo -E sh
sudo ambari-server setup --jdbc-db=mysql --jdbc-driver=/usr/share/java/mysql-connector-java.jar
sudo ambari-server install-mpack --verbose --mpack=${mpack_url}
# Hack to fix a current bug in Ambari Blueprints
sudo sed -i.bak "s/\(^    total_sinks_count = \)0$/\11/" /var/lib/ambari-server/resources/stacks/HDP/2.0.6/services/stack_advisor.py

echo "Creating Storm View..."
curl -u admin:admin -H "X-Requested-By:ambari" -X POST -d '{"ViewInstanceInfo":{"instance_name":"Storm_View","label":"Storm View","visible":true,"icon_path":"","icon64_path":"","description":"storm view","properties":{"storm.host":"'${host}'","storm.port":"8744","storm.sslEnabled":"false"},"cluster_type":"NONE"}}' http://${host}:8080/api/v1/views/Storm_Monitoring/versions/0.1.0/instances/Storm_View

#create demokitadmin user
curl -iv -u admin:admin -H "X-Requested-By: blah" -X POST -d "{\"Users/user_name\":\"${service_user}\",\"Users/password\":\"${service_password}\",\"Users/active\":\"true\",\"Users/admin\":\"true\"}" http://localhost:8080/api/v1/users

echo "Updating admin password..."
curl -iv -u admin:admin -H "X-Requested-By: blah" -X PUT -d "{ \"Users\": { \"user_name\": \"admin\", \"old_password\": \"admin\", \"password\": \"${ambari_password}\" }}" http://localhost:8080/api/v1/users/admin

cd /tmp

#solr pre-restart steps
if [ "${install_solr}" = true  ]; then
	sudo git clone https://github.com/abajwa-hw/solr-stack.git   /var/lib/ambari-server/resources/stacks/HDP/${ambari_stack_version}/services/SOLRDEMO
   cat << EOF > custom_order.json
    "SOLR_MASTER-START" : ["ZOOKEEPER_SERVER-START"],
EOF

   sudo sed -i.bak '/"dependencies for all cases",/ r custom_order.json' /var/lib/ambari-server/resources/stacks/HDP/2.5/role_command_order.json
   
   solr_config="\"solr-config\": { \"solr.download.location\": \"HDPSEARCH\", \"solr.cloudmode\": \"true\", \"solr.demo_mode\": \"true\" },"	
   echo ${solr_config} > solr-config.json
fi

sudo ambari-server restart
# Ambari blueprint cluster install
echo "Deploying HDP and HDF services..."
curl -ssLO https://github.com/seanorama/ambari-bootstrap/archive/master.zip
unzip -q master.zip -d  /tmp


cd /tmp
echo "downloading twitter flow..."
twitter_flow=$(curl -L ${nifi_flow})
#change kafka broker string for Ambari to replace later
twitter_flow=$(echo ${twitter_flow}  | sed "s/demo.hortonworks.com/${host}/g")
nifi_config="\"nifi-flow-env\" : { \"properties_attributes\" : { }, \"properties\" : { \"content\" : \"${twitter_flow}\"  }  },"
echo ${nifi_config} > nifi-config.json


echo "downloading Blueprint configs template..."
curl -sSL https://gist.github.com/abajwa-hw/73be0ce6f2b88353125ae460547ece46/raw > configuration-custom-template.json

echo "adding Nifi flow to blueprint configs template..."
sed -e "2r nifi-config.json" configuration-custom-template.json  > configuration-custom.json


if [ "${install_solr}" = true  ]; then
  echo "adding Solr to blueprint configs template..."
  sed -e "2r solr-config.json" configuration-custom.json > configuration-custom-solr.json
  sudo mv configuration-custom.json configuration-custom-nifi.json
  sudo mv configuration-custom-solr.json configuration-custom.json
  
  export ambari_services="${ambari_services} SOLR"
fi


cd /tmp/ambari-bootstrap-master/deploy
sudo cp /tmp/configuration-custom.json .


# This command might fail with 'resources' error, means Ambari isn't ready yet
echo "Waiting for 90s before deploying cluster with services: ${ambari_services}"
sleep 90
sudo -E /tmp/ambari-bootstrap-master/deploy/deploy-recommended-cluster.bash


echo Now open your browser to http://$(curl -s icanhazptr.com):8080 and login as admin/${ambari_password} to observe the cluster install

echo "Waiting for cluster to be installed..."
sleep 5

#wait until cluster deployed
ambari_pass="${ambari_password}" source /tmp/ambari-bootstrap-master/extras/ambari_functions.sh
ambari_configs
ambari_wait_request_complete 1


echo "Cluster installed. Sleeping 60s before setting up trucking demo..."
sleep 60

while ! echo exit | nc localhost 7788; do echo "waiting for Schema Registry to be fully up..."; sleep 10; done

cd /tmp
git clone https://github.com/harshn08/whoville.git
cd /tmp/whoville/templates/

echo "Creating Schemas in Registry..."
curl -H "Content-Type: application/json" -X POST -d '{ "type": "avro", "schemaGroup": "truck-sensors-kafka", "name": "raw-truck_events_avro", "description": "Raw Geo events from trucks in Kafka Topic", "compatibility": "BACKWARD", "evolve": true}' http://localhost:7788/api/v1/schemaregistry/schemas
curl -H "Content-Type: application/json" -X POST -d '{ "type": "avro", "schemaGroup": "truck-sensors-kafka", "name": "raw-truck_speed_events_avro", "description": "Raw Speed Events from trucks in Kafka Topic", "compatibility": "BACKWARD", "evolve": true}' http://localhost:7788/api/v1/schemaregistry/schemas
curl -H "Content-Type: application/json" -X POST -d '{ "type": "avro", "schemaGroup": "truck-sensors-kafka", "name": "truck_events_avro", "description": "Schema for the kafka topic named truck_events_avro", "compatibility": "BACKWARD", "evolve": true}' http://localhost:7788/api/v1/schemaregistry/schemas
curl -H "Content-Type: application/json" -X POST -d '{ "type": "avro", "schemaGroup": "truck-sensors-kafka", "name": "truck_speed_events_avro", "description": "Schema for the kafka topic named truck_speed_events_avro", "compatibility": "BACKWARD", "evolve": true}' http://localhost:7788/api/v1/schemaregistry/schemas

echo "Uploading schemas to registry..."
curl -X POST -F 'name=raw-truck_events_avro' -F 'description=ver1' -F 'file=@./schema_rawTruckEvents.avsc' http://localhost:7788/api/v1/schemaregistry/schemas/raw-truck_events_avro/versions/upload
curl -X POST -F 'name=raw-truck_speed_events_avro' -F 'description=ver1' -F 'file=@./truckspeedevents.avsc' http://localhost:7788/api/v1/schemaregistry/schemas/raw-truck_speed_events_avro/versions/upload
curl -X POST -F 'name=truck_events_avro' -F 'description=ver1' -F 'file=@./schema_geoTruckEvents.avsc' http://localhost:7788/api/v1/schemaregistry/schemas/truck_events_avro/versions/upload
curl -X POST -F 'name=truck_speed_events_avro' -F 'description=ver1' -F 'file=@./schema_TruckSpeedEvents.avsc' http://localhost:7788/api/v1/schemaregistry/schemas/truck_speed_events_avro/versions/upload

echo "Creating Kafka topics..."
/usr/hdp/current/kafka-broker/bin/kafka-topics.sh --create --zookeeper ${host}:2181 --replication-factor 1 --partitions 1 --topic raw-truck_events_avro
/usr/hdp/current/kafka-broker/bin/kafka-topics.sh --create --zookeeper ${host}:2181 --replication-factor 1 --partitions 1 --topic raw-truck_speed_events_avro
/usr/hdp/current/kafka-broker/bin/kafka-topics.sh --create --zookeeper ${host}:2181 --replication-factor 1 --partitions 1 --topic truck_events_avro
/usr/hdp/current/kafka-broker/bin/kafka-topics.sh --create --zookeeper ${host}:2181 --replication-factor 1 --partitions 1 --topic truck_speed_events_avro
/usr/hdp/current/kafka-broker/bin/kafka-topics.sh --zookeeper ${host}:2181 --list

while ! echo exit | nc localhost 16010; do echo "waiting for Hbase master to be fully up..."; sleep 10; done
while ! echo exit | nc localhost 16030; do echo "waiting for Hbase RS to be fully up..."; sleep 10; done

echo "Creating Hbase Tables..."
echo "create 'driver_speed','0'" | hbase shell
echo "create 'driver_violations','0'" | hbase shell
echo "create 'violation_events','events'" | hbase shell


echo "Creating Phoenix Tables..."
# set phoenix path for sql script and data
export PHOENIX_PATH=/tmp/whoville/phoenix
/usr/hdp/current/phoenix-client/bin/sqlline.py $(hostname -f):2181:/hbase-unsecure $PHOENIX_PATH/create_tables.sql 
/usr/hdp/current/phoenix-client/bin/psql.py -t DRIVERS $PHOENIX_PATH/data/drivers.csv
/usr/hdp/current/phoenix-client/bin/psql.py -t TIMESHEET $PHOENIX_PATH/data/timesheet.csv



## SAM
while ! echo exit | nc localhost 7777; do echo "waiting for SAM to be fully up..."; sleep 10; done

export host=$(hostname -f)
echo "Creating SAM artifacts for host ${host} ..."

echo "Register a service pool cluster..."
curl -H 'content-type: application/json' http://${host}:7777/api/v1/catalog/clusters -d @- <<EOF
{"name":"${cluster_name}","description":"Registering Cluster : ${cluster_name}","ambariImportUrl":"http://${host}:8080/api/v1/clusters/${cluster_name}"}
EOF

echo "Import cluster services with Ambari..."
curl -H 'content-type: application/json' http://${host}:7777/api/v1/catalog/cluster/import/ambari -d @- <<EOF
{"clusterId":1,"ambariRestApiRootUrl":"http://${host}:8080/api/v1/clusters/${cluster_name}","username":"admin","password":"${ambari_password}"}
EOF

echo "Create SAM namespace/environment..."
curl -H 'content-type: application/json' http://${host}:7777/api/v1/catalog/namespaces -d @- <<EOF
{"name":"TruckingDemo","description":"Trucking Environment","streamingEngine":"STORM"}
EOF

echo "Add services to SAM environment..."
curl -H 'content-type: application/json' http://${host}:7777/api/v1/catalog/namespaces/1/mapping/bulk -d @- <<EOF
[{"clusterId":1,"serviceName":"KAFKA","namespaceId":1},{"clusterId":1,"serviceName":"DRUID","namespaceId":1},{"clusterId":1,"serviceName":"STORM","namespaceId":1},{"clusterId":1,"serviceName":"HDFS","namespaceId":1},{"clusterId":1,"serviceName":"HDFS","namespaceId":1},{"clusterId":1,"serviceName":"HBASE","namespaceId":1},{"clusterId":1,"serviceName":"ZOOKEEPER","namespaceId":1}]
EOF

echo "Adding the SAM Custom udf and processors..."
curl -F udfJarFile=@/tmp/whoville/SAMExtensions/sam-custom-udf-0.0.5.jar -F 'udfConfig={"name":"TIMESTAMP_LONG","displayName":"TIMESTAMP_LONG","description":"Converts a String timestamp to Timestamp Long","type":"FUNCTION","className":"hortonworks.hdf.sam.custom.udf.time.ConvertToTimestampLong"};type=application/json' -X POST http://${host}:7777/api/v1/catalog/streams/udfs
curl -F udfJarFile=@/tmp/whoville/SAMExtensions/sam-custom-udf-0.0.5.jar -F 'udfConfig={"name":"GET_WEEK","displayName":"GET_WEEK","description":"For a given data time string, returns week of the input date","type":"FUNCTION","className":"hortonworks.hdf.sam.custom.udf.time.GetWeek"};type=application/json' -X POST http://${host}:7777/api/v1/catalog/streams/udfs
curl -F udfJarFile=@/tmp/whoville/SAMExtensions/sam-custom-udf-0.0.5.jar -F 'udfConfig={"name":"ROUND","displayName":"ROUND","description":"Rounds a double to an integer","type":"FUNCTION","className":"hortonworks.hdf.sam.custom.udf.math.Round"};type=application/json' -X POST http://${host}:7777/api/v1/catalog/streams/udfs

curl -sS -X POST -i -F jarFile=@/tmp/whoville/SAMExtensions/sam-custom-processor-0.0.5-jar-with-dependencies.jar http://${host}:7777/api/v1/catalog/streams/componentbundles/PROCESSOR/custom -F customProcessorInfo=@/tmp/whoville/SAMExtensions/phoenix-enrich-truck-demo.json
curl -sS -X POST -i -F jarFile=@/tmp/whoville/SAMExtensions/sam-custom-processor-0.0.5.jar http://${host}:7777/api/v1/catalog/streams/componentbundles/PROCESSOR/custom -F customProcessorInfo=@/tmp/whoville/SAMExtensions/enrich-weather.json
curl -sS -X POST -i -F jarFile=@/tmp/whoville/SAMExtensions/sam-custom-processor-0.0.5a.jar http://${host}:7777/api/v1/catalog/streams/componentbundles/PROCESSOR/custom -F customProcessorInfo=@/tmp/whoville/SAMExtensions/normalize-model-features.json


echo "Importing truck_demo_pmml.xml..."
curl -sS -i -F pmmlFile=@/tmp/whoville/SAMExtensions/truck_demo_pmml.xml -F 'modelInfo={"name":"'DriverViolationPredictionModel'","namespace":"ml_model","uploadedFileName":"'truck_demo_pmml.xml'"};type=text/json' -X POST http://${host}:7777/api/v1/catalog/ml/models

#replace host/cluster names in template json
sed -i "s/demo.hortonworks.com/${host}/g" /tmp/whoville/topology/truckingapp.json
sed -i "s/Whoville/${cluster_name}/g" /tmp/whoville/topology/truckingapp.json

echo "import topology to SAM..."
curl -F file=@/tmp/whoville/topology/truckingapp.json -F topologyName=TruckingDemo -F namespaceId=1 -X POST http://${host}:7777/api/v1/catalog/topologies/actions/import

echo "Deploying SAM topology..."
curl -X POST http://${host}:7777/api/v1/catalog/topologies/1/versions/1/actions/deploy
echo "Waiting 180s for SAM topology deployment..."
sleep 180
echo "Checking SAM topology deployment status..."
curl -X GET http://${host}:7777/api/v1/catalog/topologies/1/deploymentstate | grep -Po '"name":"([A-Z_]+)'| grep -Po '([A-Z_]+)'




echo "Starting simulator..." 
export DATA_LOADER_HOME=/tmp/whoville/data_simulator
cd $DATA_LOADER_HOME
#extract routes data 
sudo tar -zxvf $DATA_LOADER_HOME/routes.tar.gz

nohup sudo java -cp $DATA_LOADER_HOME/stream-simulator-jar-with-dependencies.jar \
hortonworks.hdp.refapp.trucking.simulator.SimulationRegistrySerializerRunnerApp \
20000 \
hortonworks.hdp.refapp.trucking.simulator.impl.domain.transport.Truck \
hortonworks.hdp.refapp.trucking.simulator.impl.collectors.KafkaEventSerializedWithRegistryCollector \
1 \
$DATA_LOADER_HOME/routes/midwest/ \
10000 \
$(hostname -f):6667 \
http://$(hostname -f):7788/api/v1 \
ALL_STREAMS \
NONSECURE &


echo "Updating Zeppelin notebooks"
sudo curl -sSL https://raw.githubusercontent.com/hortonworks-gallery/zeppelin-notebooks/master/update_all_notebooks.sh | sudo -E sh 
sudo -u zeppelin hdfs dfs -rmr /user/zeppelin/notebook/*
sudo -u zeppelin hdfs dfs -put /usr/hdp/current/zeppelin-server/notebook/* /user/zeppelin/notebook/


sudo curl -u admin:${ambari_password} -H 'X-Requested-By: blah' -X POST -d "
{
   \"RequestInfo\":{
      \"command\":\"RESTART\",
      \"context\":\"Restart Zeppelin\",
      \"operation_level\":{
         \"level\":\"HOST\",
         \"cluster_name\":\"${cluster_name}\"
      }
   },
   \"Requests/resource_filters\":[
      {
         \"service_name\":\"ZEPPELIN\",
         \"component_name\":\"ZEPPELIN_MASTER\",
         \"hosts\":\"${host}\"
      }
   ]
}" http://localhost:8080/api/v1/clusters/${cluster_name}/requests  


cd
echo "Setup complete!"
