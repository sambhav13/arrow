#!/usr/bin/env bash
#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Set up environment and working directory
cd /apache-arrow

export ARROW_BUILD_TYPE=release
export ARROW_HOME=$(pwd)/arrow
CONDA_BASE=/home/ubuntu/miniconda
export LD_LIBRARY_PATH=${ARROW_HOME}/lib:${CONDA_BASE}/lib:${LD_LIBRARY_PATH}
export PYTHONPATH=${ARROW_HOME}/python:${PYTHONPATH}
export MAVEN_OPTS="-Xmx2g -XX:ReservedCodeCacheSize=512m"

# Activate our pyarrow-dev conda env
source activate pyarrow-dev

# Build arrow-cpp and install
pushd arrow/cpp
rm -rf build/*
mkdir -p build
cd build/
cmake -DARROW_PYTHON=on -DARROW_HDFS=on -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$ARROW_HOME ..
make -j4
if [[ $? -ne 0 ]]; then
    exit 1
fi
make install
popd

# Build pyarrow and install inplace
pushd arrow/python
python setup.py clean
python setup.py build_ext --build-type=release --inplace
if [[ $? -ne 0 ]]; then
    exit 1
fi
popd

# Install Arrow to local maven repo and get the version
pushd arrow/java
echo "Building and installing Arrow Java"
mvn -DskipTests -Drat.skip=true clean install
ARROW_VERSION=`mvn org.apache.maven.plugins:maven-help-plugin:2.1.1:evaluate -Dexpression=project.version | sed -n -e '/^\[.*\]/ !{ /^[0-9]/ { p; q } }'`
echo "Using Arrow version $ARROW_VERSION"
popd

# Build Spark with Arrow
SPARK_REPO=https://github.com/apache/spark.git
SPARK_BRANCH=master

# Get the Spark repo if not in image already
if [ ! -d "$(pwd)/spark" ]; then
    export GIT_COMMITTER_NAME="Nobody"
    export GIT_COMMITTER_EMAIL="nobody@nowhere.com"
    git clone "$SPARK_REPO"
fi

pushd spark

# Make sure branch has no modifications
git checkout "$SPARK_BRANCH"
git reset --hard HEAD

# Update Spark pom with the Arrow version just installed and build Spark, need package phase for pyspark
sed -i -e "s/\(.*<arrow.version>\).*\(<\/arrow.version>\)/\1$ARROW_VERSION\2/g" ./pom.xml
echo "Building Spark with Arrow $ARROW_VERSION"
#build/mvn -DskipTests clean package
build/mvn -DskipTests package

# Run Arrow related Scala tests only, NOTE: -Dtest=_NonExist_ is to enable surefire test discovery without running any tests so that Scalatest can run
SPARK_SCALA_TESTS="org.apache.spark.sql.execution.arrow,org.apache.spark.sql.execution.vectorized.ColumnarBatchSuite,org.apache.spark.sql.execution.vectorized.ArrowColumnVectorSuite"
echo "Testing Spark: $SPARK_SCALA_TESTS"
# TODO: should be able to only build spark-sql tests with adding "-pl sql/core" but not currently working
build/mvn -Dtest=none -DwildcardSuites="$SPARK_SCALA_TESTS" test
if [[ $? -ne 0 ]]; then
    exit 1
fi

# Run pyarrow related Python tests only
SPARK_PYTHON_TESTS="ArrowTests PandasUDFTests ScalarPandasUDF GroupbyApplyPandasUDFTests GroupbyAggPandasUDFTests"
echo "Testing PySpark: $SPARK_PYTHON_TESTS"
SPARK_TESTING=1 bin/pyspark pyspark.sql.tests $SPARK_PYTHON_TESTS 
if [[ $? -ne 0 ]]; then
    exit 1
fi
popd

# Clean up
echo "Cleaning up.."
source deactivate

