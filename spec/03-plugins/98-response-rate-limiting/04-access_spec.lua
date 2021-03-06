local cjson = require "cjson"
local helpers = require "spec.helpers"
local timestamp = require "kong.tools.timestamp"

local REDIS_HOST = "127.0.0.1"
local REDIS_PORT = 6379
local REDIS_PASSWORD = ""

local SLEEP_TIME = 1

local function wait(second_offset)
  -- If the minute elapses in the middle of the test, then the test will
  -- fail. So we give it this test 30 seconds to execute, and if the second
  -- of the current minute is > 30, then we wait till the new minute kicks in
  local current_second = timestamp.get_timetable().sec
  if current_second > (second_offset or 0) then
    os.execute("sleep "..tostring(60 - current_second))
  end
end

wait() -- Wait before starting

local function flush_redis()
  local redis = require "resty.redis"
  local red = redis:new()
  red:set_timeout(2000)
  local ok, err = red:connect(REDIS_HOST, REDIS_PORT)
  if not ok then
    error("failed to connect to Redis: "..err)
  end

  if REDIS_PASSWORD and REDIS_PASSWORD ~= "" then
    local ok, err = red:auth(REDIS_PASSWORD)
    if not ok then
      error("failed to connect to Redis: "..err)
    end
  end

  red:flushall()
  red:close()
end

for i, policy in ipairs({"local", "cluster", "redis"}) do
  describe("#ci Plugin: response-ratelimiting (access) with policy: "..policy, function()
    setup(function()
      flush_redis()
      helpers.dao:drop_schema()
      assert(helpers.dao:run_migrations())
      assert(helpers.start_kong())

      local consumer1 = assert(helpers.dao.consumers:insert {custom_id = "provider_123"})
      assert(helpers.dao.keyauth_credentials:insert {
        key = "apikey123",
        consumer_id = consumer1.id
      })

      local consumer2 = assert(helpers.dao.consumers:insert {custom_id = "provider_124"})
      assert(helpers.dao.keyauth_credentials:insert {
        key = "apikey124",
        consumer_id = consumer2.id
      })

      local consumer3 = assert(helpers.dao.consumers:insert {custom_id = "provider_125"})
      assert(helpers.dao.keyauth_credentials:insert {
        key = "apikey125",
        consumer_id = consumer3.id
      })

      local api = assert(helpers.dao.apis:insert {
        request_host = "test1.com",
        upstream_url = "http://httpbin.org"
      })
      assert(helpers.dao.plugins:insert {
        name = "response-ratelimiting",
        api_id = api.id,
        config = {
          fault_tolerant = false,
          policy = policy,
          redis_host = REDIS_HOST,
          redis_port = REDIS_PORT,
          redis_password = REDIS_PASSWORD,
          limits = {video = {minute = 6}}
        }
      })

      api = assert(helpers.dao.apis:insert {
        request_host = "test2.com",
        upstream_url = "http://httpbin.org"
      })
      assert(helpers.dao.plugins:insert {
        name = "response-ratelimiting",
        api_id = api.id,
        config = {
          fault_tolerant = false,
          policy = policy,
          redis_host = REDIS_HOST,
          redis_port = REDIS_PORT,
          redis_password = REDIS_PASSWORD,
          limits = {video = {minute = 6, hour = 10}, image = {minute = 4}}
        }
      })

      api = assert(helpers.dao.apis:insert {
        request_host = "test3.com",
        upstream_url = "http://httpbin.org"
      })
      assert(helpers.dao.plugins:insert {
        name = "key-auth",
        api_id = api.id
      })
      assert(helpers.dao.plugins:insert {
        name = "response-ratelimiting",
        api_id = api.id,
        config = {limits = {video = {minute = 6}}}
      })
      assert(helpers.dao.plugins:insert {
        name = "response-ratelimiting",
        api_id = api.id,
        consumer_id = consumer1.id,
        config = {
          fault_tolerant = false,
          policy = policy,
          redis_host = REDIS_HOST,
          redis_port = REDIS_PORT,
          redis_password = REDIS_PASSWORD,
          limits = {video = {minute = 2}}
        }
      })

      api = assert(helpers.dao.apis:insert {
        request_host = "test6.com",
        upstream_url = "http://httpbin.org"
      })
      assert(helpers.dao.plugins:insert {
        name = "response-ratelimiting",
        api_id = api.id,
        config = {
          fault_tolerant = true,
          policy = policy,
          redis_host = REDIS_HOST,
          redis_port = REDIS_PORT,
          redis_password = REDIS_PASSWORD,
          limits = {video = {minute = 2}}
        }
      })

      api = assert(helpers.dao.apis:insert {
        request_host = "test7.com",
        upstream_url = "http://httpbin.org"
      })
      assert(helpers.dao.plugins:insert {
        name = "response-ratelimiting",
        api_id = api.id,
        config = {
          fault_tolerant = false,
          policy = policy,
          redis_host = REDIS_HOST,
          redis_port = REDIS_PORT,
          redis_password = REDIS_PASSWORD,
          block_on_first_violation = true,
          limits = {
            video = {
              minute = 6,
              hour = 10
            },
            image = {
              minute = 4
            }
          }
        }
      })

      api = assert(helpers.dao.apis:insert {
        request_host = "test8.com",
        upstream_url = "http://httpbin.org"
      })
      assert(helpers.dao.plugins:insert {
        name = "response-ratelimiting",
        api_id = api.id,
        config = {
          fault_tolerant = false,
          policy = policy,
          redis_host = REDIS_HOST,
          redis_port = REDIS_PORT,
          redis_password = REDIS_PASSWORD,
          limits = {video = {minute = 6, hour = 10}, image = {minute = 4}}
        }
      })
    end)

    teardown(function()
      helpers.stop_kong()
    end)

    local client, admin_client
    before_each(function()
      wait(45)
      client = helpers.proxy_client()
      admin_client = helpers.admin_client()
    end)
    after_each(function()
      if client then client:close() end
      if admin_client then admin_client:close() end
    end)

    describe("Without authentication (IP address)", function()
      it("blocks if exceeding limit", function()
        for i = 1, 6 do
          local res = assert(client:send {
            method = "GET",
            path = "/response-headers?x-kong-limit=video=1, test=5",
            headers = {
              ["Host"] = "test1.com"
            }
          })

          ngx.sleep(SLEEP_TIME) -- Wait for async timer to increment the limit

          assert.res_status(200, res)
          assert.equal(6, tonumber(res.headers["x-ratelimit-limit-video-minute"]))
          assert.equal(6 - i, tonumber(res.headers["x-ratelimit-remaining-video-minute"]))
        end

        local res = assert(client:send {
          method = "GET",
          path = "/response-headers?x-kong-limit=video=1",
          headers = {
            ["Host"] = "test1.com"
          }
        })
        local body = assert.res_status(429, res)
        assert.equal([[]], body)
      end)

      it("handles multiple limits", function()
        for i = 1, 3 do
          local res = assert(client:send {
            method = "GET",
            path = "/response-headers?x-kong-limit=video=2, image=1",
            headers = {
              ["Host"] = "test2.com"
            }
          })

          ngx.sleep(SLEEP_TIME) -- Wait for async timer to increment the limit

          assert.res_status(200, res)
          assert.equal(6, tonumber(res.headers["x-ratelimit-limit-video-minute"]))
          assert.equal(6 - (i * 2), tonumber(res.headers["x-ratelimit-remaining-video-minute"]))
          assert.equal(10, tonumber(res.headers["x-ratelimit-limit-video-hour"]))
          assert.equal(10 - (i * 2), tonumber(res.headers["x-ratelimit-remaining-video-hour"]))
          assert.equal(4, tonumber(res.headers["x-ratelimit-limit-image-minute"]))
          assert.equal(4 - i, tonumber(res.headers["x-ratelimit-remaining-image-minute"]))
        end

        local res = assert(client:send {
          method = "GET",
          path = "/response-headers?x-kong-limit=video=2, image=1",
          headers = {
            ["Host"] = "test2.com"
          }
        })
        local body = assert.res_status(429, res)
        assert.equal([[]], body)
        assert.equal(0, tonumber(res.headers["x-ratelimit-remaining-video-minute"]))
        assert.equal(4, tonumber(res.headers["x-ratelimit-remaining-video-hour"]))
        assert.equal(1, tonumber(res.headers["x-ratelimit-remaining-image-minute"]))
      end)
    end)

    describe("With authentication", function()
      describe("API-specific plugin", function()
        it("blocks if exceeding limit and a per consumer setting", function()
          for i = 1, 2 do
            local res = assert(client:send {
              method = "GET",
              path = "/response-headers?apikey=apikey123&x-kong-limit=video=1",
              headers = {
                ["Host"] = "test3.com"
              }
            })

            ngx.sleep(SLEEP_TIME) -- Wait for async timer to increment the limit

            assert.res_status(200, res)
            assert.equal(2, tonumber(res.headers["x-ratelimit-limit-video-minute"]))
            assert.equal(2 - i, tonumber(res.headers["x-ratelimit-remaining-video-minute"]))
          end

          -- Third query, while limit is 2/minute
          local res = assert(client:send {
            method = "GET",
            path = "/response-headers?apikey=apikey123&x-kong-limit=video=1",
            headers = {
              ["Host"] = "test3.com"
            }
          })
          local body = assert.res_status(429, res)
          assert.equal([[]], body)
          assert.equal(0, tonumber(res.headers["x-ratelimit-remaining-video-minute"]))
          assert.equal(2, tonumber(res.headers["x-ratelimit-limit-video-minute"]))
        end)

        it("blocks if exceeding limit and a per consumer setting", function()
          for i = 1, 6 do
            local res = assert(client:send {
              method = "GET",
              path = "/response-headers?apikey=apikey124&x-kong-limit=video=1",
              headers = {
                ["Host"] = "test3.com"
              }
            })

            ngx.sleep(SLEEP_TIME) -- Wait for async timer to increment the limit

            assert.res_status(200, res)
            assert.equal(6, tonumber(res.headers["x-ratelimit-limit-video-minute"]))
            assert.equal(6 - i, tonumber(res.headers["x-ratelimit-remaining-video-minute"]))
          end

          local res = assert(client:send {
            method = "GET",
            path = "/response-headers?apikey=apikey124",
            headers = {
              ["Host"] = "test3.com"
            }
          })
          assert.res_status(200, res)
          assert.equal(0, tonumber(res.headers["x-ratelimit-remaining-video-minute"]))
          assert.equal(6, tonumber(res.headers["x-ratelimit-limit-video-minute"]))
        end)

        it("blocks if exceeding limit", function()
          for i = 1, 6 do
            local res = assert(client:send {
              method = "GET",
              path = "/response-headers?apikey=apikey125&x-kong-limit=video=1",
              headers = {
                ["Host"] = "test3.com"
              }
            })

            ngx.sleep(SLEEP_TIME) -- Wait for async timer to increment the limit

            assert.res_status(200, res)
            assert.are.same(6, tonumber(res.headers["x-ratelimit-limit-video-minute"]))
            assert.are.same(6 - i, tonumber(res.headers["x-ratelimit-remaining-video-minute"]))
          end

          -- Third query, while limit is 2/minute
          local res = assert(client:send {
            method = "GET",
            path = "/response-headers?apikey=apikey125&x-kong-limit=video=1",
            headers = {
              ["Host"] = "test3.com"
            }
          })
          local body = assert.res_status(429, res)
          assert.equal([[]], body)
          assert.equal(0, tonumber(res.headers["x-ratelimit-remaining-video-minute"]))
          assert.equal(6, tonumber(res.headers["x-ratelimit-limit-video-minute"]))
        end)
      end)
    end)

    describe("Upstream usage headers", function()
      it("should append the headers with multiple limits", function()
        local res = assert(client:send {
          method = "GET",
          path = "/get",
          headers = {
            ["Host"] = "test8.com"
          }
        })
        local body = cjson.decode(assert.res_status(200, res))
        assert.equal(4, tonumber(body.headers["X-Ratelimit-Remaining-Image"]))
        assert.equal(6, tonumber(body.headers["X-Ratelimit-Remaining-Video"]))

        -- Actually consume the limits
        local res = assert(client:send {
          method = "GET",
          path = "/response-headers?x-kong-limit=video=2, image=1",
          headers = {
            ["Host"] = "test8.com"
          }
        })
        assert.res_status(200, res)

        ngx.sleep(SLEEP_TIME) -- Wait for async timer to increment the limit

        local res = assert(client:send {
          method = "GET",
          path = "/get",
          headers = {
            ["Host"] = "test8.com"
          }
        })
        local body = cjson.decode(assert.res_status(200, res))
        assert.equal(3, tonumber(body.headers["X-Ratelimit-Remaining-Image"]))
        assert.equal(4, tonumber(body.headers["X-Ratelimit-Remaining-Video"]))
      end)
    end)

    it("should block on first violation", function()
      local res = assert(client:send {
        method = "GET",
        path = "/response-headers?x-kong-limit=video=2, image=4",
        headers = {
          ["Host"] = "test7.com"
        }
      })
      assert.res_status(200, res)

      ngx.sleep(SLEEP_TIME) -- Wait for async timer to increment the limit

      local res = assert(client:send {
        method = "GET",
        path = "/response-headers?x-kong-limit=video=2",
        headers = {
          ["Host"] = "test7.com"
        }
      })
      local body = assert.res_status(429, res)
      assert.equal([[{"message":"API rate limit exceeded for 'image'"}]], body)
    end)

    if policy == "cluster" then
      describe("Fault tolerancy", function()

        before_each(function()
          helpers.kill_all()
          helpers.dao:drop_schema()
          assert(helpers.dao:run_migrations())

          local api1 = assert(helpers.dao.apis:insert {
            request_host = "failtest1.com",
            upstream_url = "http://httpbin.org"
          })
          assert(helpers.dao.plugins:insert {
            name = "response-ratelimiting",
            api_id = api1.id,
            config = {
              fault_tolerant = false,
              policy = policy,
              redis_host = REDIS_HOST,
              redis_port = REDIS_PORT,
              redis_password = REDIS_PASSWORD,
              limits = {video = {minute = 6}}
            }
          })

          local api2 = assert(helpers.dao.apis:insert {
            request_host = "failtest2.com",
            upstream_url = "http://httpbin.org"
          })
          assert(helpers.dao.plugins:insert {
            name = "response-ratelimiting",
            api_id = api2.id,
            config = {
              fault_tolerant = true,
              policy = policy,
              redis_host = REDIS_HOST,
              redis_port = REDIS_PORT,
              redis_password = REDIS_PASSWORD,
              limits = {video = {minute = 6}}
            }
          })

          assert(helpers.start_kong())
        end)

        teardown(function()
          helpers.kill_all()
          helpers.dao:drop_schema()
          assert(helpers.dao:run_migrations())
        end)

        it("does not work if an error occurs", function()
          local res = assert(helpers.proxy_client():send {
            method = "GET",
            path = "/response-headers?x-kong-limit=video=1",
            headers = {
              ["Host"] = "failtest1.com"
            }
          })
          assert.res_status(200, res)
          assert.equal(6, tonumber(res.headers["x-ratelimit-limit-video-minute"]))
          assert.equal(5, tonumber(res.headers["x-ratelimit-remaining-video-minute"]))

          -- Simulate an error on the database
          local err = helpers.dao.response_ratelimiting_metrics:drop_table(helpers.dao.response_ratelimiting_metrics.table)
          assert.falsy(err)

          -- Make another request
          local res = assert(helpers.proxy_client():send {
            method = "GET",
            path = "/response-headers?x-kong-limit=video=1",
            headers = {
              ["Host"] = "failtest1.com"
            }
          })
          local body = assert.res_status(500, res)
          assert.equal([[{"message":"An unexpected error occurred"}]], body)
        end)

        it("keeps working if an error occurs", function()
          local res = assert(helpers.proxy_client():send {
            method = "GET",
            path = "/response-headers?x-kong-limit=video=1",
            headers = {
              ["Host"] = "failtest2.com"
            }
          })
          assert.res_status(200, res)
          assert.equal(6, tonumber(res.headers["x-ratelimit-limit-video-minute"]))
          assert.equal(5, tonumber(res.headers["x-ratelimit-remaining-video-minute"]))

          -- Simulate an error on the database
          local err = helpers.dao.response_ratelimiting_metrics:drop_table(helpers.dao.response_ratelimiting_metrics.table)
          assert.falsy(err)

          -- Make another request
          local res = assert(helpers.proxy_client():send {
            method = "GET",
            path = "/response-headers?x-kong-limit=video=1",
            headers = {
              ["Host"] = "failtest2.com"
            }
          })
          assert.res_status(200, res)
          assert.is_nil(res.headers["x-ratelimit-limit-video-minute"])
          assert.is_nil(res.headers["x-ratelimit-remaining-video-minute"])
        end)
      end)
    end

    describe("Expirations", function()
      local api
      setup(function()
        helpers.stop_kong()
        helpers.dao:drop_schema()
        assert(helpers.dao:run_migrations())
        assert(helpers.start_kong())

        api = assert(helpers.dao.apis:insert {
          request_host = "expire1.com",
          upstream_url = "http://httpbin.org"
        })
        assert(helpers.dao.plugins:insert {
          name = "response-ratelimiting",
          api_id = api.id,
          config = {
            policy = policy,
            redis_host = REDIS_HOST,
            redis_port = REDIS_PORT,
            redis_password = REDIS_PASSWORD,
            fault_tolerant = false,
            limits = {video = {minute = 6}}
          }
        })
      end)

      it("expires a counter", function()
        local periods = timestamp.get_timestamps()

        local res = assert(client:send {
          method = "GET",
          path = "/response-headers?x-kong-limit=video=1",
          headers = {
            ["Host"] = "expire1.com"
          }
        })

        ngx.sleep(SLEEP_TIME) -- Wait for async timer to increment the limit

        assert.res_status(200, res)
        assert.equal(6, tonumber(res.headers["x-ratelimit-limit-video-minute"]))
        assert.equal(5, tonumber(res.headers["x-ratelimit-remaining-video-minute"]))

        if policy == "local" then
          local res = assert(admin_client:send {
            method = "GET",
            path = "/cache/"..string.format("response-ratelimit:%s:%s:%s:%s:%s", api.id, "127.0.0.1", periods.minute, "video", "minute")
          })
          local body = assert.res_status(200, res)
          assert.equal([[{"message":1}]], body)
        end

        ngx.sleep(61) -- Wait for counter to expire

        local res = assert(client:send {
          method = "GET",
          path = "/response-headers?x-kong-limit=video=1",
          headers = {
            ["Host"] = "expire1.com"
          }
        })

        ngx.sleep(SLEEP_TIME) -- Wait for async timer to increment the limit

        assert.res_status(200, res)
        assert.equal(6, tonumber(res.headers["x-ratelimit-limit-video-minute"]))
        assert.equal(5, tonumber(res.headers["x-ratelimit-remaining-video-minute"]))

        if policy == "local" then
          local res = assert(admin_client:send {
            method = "GET",
            path = "/cache/"..string.format("response-ratelimit:%s:%s:%s:%s:%s", api.id, "127.0.0.1", periods.minute, "video", "minute")
          })
          assert.res_status(404, res)
        end
      end)
    end)
  end)
end
