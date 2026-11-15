import unittest
from copy import deepcopy

from transport import UnsafeProfile, client_config, ssh_proxy_options, tor_arguments


class RouteContractTests(unittest.TestCase):
    def setUp(self):
        self.profile = {"server": "vpn.example:443", "auth": "fixture",
                        "tls": {"sni": "vpn.example", "insecure": False}}

    def test_profile_is_restricted_to_one_local_proxy(self):
        result = client_config(self.profile, 19081)
        self.assertEqual(result["socks5"], {"listen": "127.0.0.1:19081"})
        self.assertEqual(set(result), {"server", "auth", "tls", "socks5"})
        self.assertNotIn("socks5", self.profile)

    def test_profiles_cannot_inject_another_outbound_or_bypass_tls(self):
        for mutation in ({"tun": {"name": "bad"}}, {"http": {"listen": "0.0.0.0:80"}},
                         {"tls": {"sni": "vpn.example", "insecure": True}}):
            profile = deepcopy(self.profile)
            profile.update(mutation)
            with self.subTest(mutation=list(mutation)), self.assertRaises(UnsafeProfile):
                client_config(profile, 19081)

    def test_tor_is_configured_to_use_only_the_local_vpn_proxy(self):
        args = tor_arguments("/usr/bin/tor", "/private/tmp/tor-fixture", 19081, 19082)
        self.assertEqual(args[args.index("--Socks5Proxy") + 1], "127.0.0.1:19081")
        self.assertEqual(args[args.index("--SocksPort") + 1], "127.0.0.1:19082")
        with self.assertRaises(UnsafeProfile):
            tor_arguments("/usr/bin/tor", "/private/tmp/tor-fixture", 19081, 19081)

    def test_ssh_does_not_reuse_an_existing_direct_master(self):
        args = ssh_proxy_options(19082)
        self.assertIn("ControlMaster=no", args)
        self.assertIn("ControlPath=none", args)
        self.assertIn("StrictHostKeyChecking=yes", args)
        self.assertIn("ProxyJump=none", args)
        with self.assertRaises(UnsafeProfile):
            ssh_proxy_options(0)


if __name__ == "__main__":
    unittest.main()
