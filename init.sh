#!/bin/bash
if [[ ${HOSTNAME} == 'redis-0' ]]; then
  redis-server /redis-config/alpha.conf
else
  redis-server /redis-config/beta.conf
fi
