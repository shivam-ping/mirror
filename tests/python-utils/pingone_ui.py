import json
import logging
import os
import ssl
import unittest

import boto3
import chromedriver_autoinstaller
import requests
import requests_oauthlib
import selenium.common.exceptions
from selenium import webdriver
from selenium.webdriver.common.by import By
import tenacity
import urllib3
import warnings

from pingone import common as p1_utils

USER = os.getenv("USER")
SSM = boto3.client("ssm")
ENV_METADATA_PARAM_NAME = f"{os.getenv('CUSTOMER_SSO_SSM_PATH_PREFIX', f'{USER}/pcpt/customer/sso')}/environment-metadata"

ENV_METADATA_PARAM = SSM.get_parameter(
    Name=ENV_METADATA_PARAM_NAME, WithDecryption=False
)
ENV_METADATA = json.loads(ENV_METADATA_PARAM.get("Parameter").get("Value"))
ENV_ID = ENV_METADATA.get("pingOneInformation").get("environmentId")
ENV_UI_URL = f"https://console-staging.pingone.com/?env={ENV_ID}#home?nav=home"

logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO)


class ConsoleUILoginTestBase(unittest.TestCase):
    tenant_name = ""
    environment = ""
    username = ""
    password = ""
    group_names = []
    p1_client = None
    p1_environment_endpoints = None
    p1_session = None

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        chromedriver_autoinstaller.install()
        cls.tenant_name = os.getenv("TENANT_NAME")
        cls.environment = os.getenv("ENV", "dev")
        cls.username = f"sso-test-user-{cls.tenant_name}"
        cls.password = "2FederateM0re!"
        cls.group_names = [
            "argo-pingbeluga",
            "os-ping",
            f"{cls.tenant_name}-{cls.environment}-pa-admin",
            f"{cls.tenant_name}-{cls.environment}-pf-roleadmin",
            cls.tenant_name,
        ]
        cls.p1_client = p1_utils.get_client()
        cls.p1_session = requests_oauthlib.OAuth2Session(
            cls.p1_client["client_id"], token=cls.p1_client["token"]
        )
        cls.p1_environment_endpoints = p1_utils.EnvironmentEndpoints(
            p1_utils.API_LOCATION, ENV_ID
        )
        cls.delete_pingone_user()
        cls.create_pingone_user()

    @classmethod
    def tearDownClass(cls):
        cls.p1_session.close()
        cls.delete_pingone_user()

    def setUp(self):
        options = webdriver.ChromeOptions()
        # Ignore certificate error warning page from chrome
        options.add_argument("--ignore-ssl-errors=yes")
        options.add_argument("--ignore-certificate-errors")
        options.add_argument("--headless=new")  # run in headless mode in CICD
        options.add_argument("--no-sandbox")  # run in Docker
        options.add_argument("--disable-dev-shm-usage")  # run in Docker
        self.browser = webdriver.Chrome(options=options)
        self.addCleanup(self.browser.quit)

    @classmethod
    def create_pingone_user(cls):
        """
        Get group IDs for dev/cicd
        Get population ID for dev/cicd
        Create a user in population
        Add role to user
        Add groups to user
        """

        population_id = p1_utils.get_population_id(
            token_session=cls.p1_session,
            endpoint=cls.p1_environment_endpoints.populations,
            name=cls.tenant_name,
        )

        groups = {}
        for group in cls.group_names:
            group_id = p1_utils.get_group_id(
                token_session=cls.p1_session,
                endpoint=cls.p1_environment_endpoints.groups,
                group_name=group,
            )
            if group_id:
                groups[group] = group_id

        user_payload = {
            "email": "do-not-reply@pingidentity.com",
            "name": {"given": cls.username, "family": "User"},
            "population": {"id": population_id},
            "username": cls.username,
            "password": {"value": cls.password, "forceChange": "false"},
        }

        user_id = p1_utils.create_user(
            token_session=cls.p1_session,
            endpoint=f'{cls.p1_environment_endpoints.users}?filter=username sw "{cls.username}"',
            name=cls.username,
            payload=user_payload,
        )

        identity_data_read_only_role_id = p1_utils.get_role_id(
            token_session=cls.p1_session,
            endpoint=cls.p1_environment_endpoints.roles,
            name="Identity Data Read Only",
        )

        p1_utils.add_role_to_user(
            token_session=cls.p1_session,
            endpoint=cls.p1_environment_endpoints.users,
            user_id=user_id,
            role_id=identity_data_read_only_role_id,
            environment_id=ENV_ID,
        )

        p1_utils.add_groups_to_user(
            token_session=cls.p1_session,
            endpoint=cls.p1_environment_endpoints.users,
            user_id=user_id,
            group_ids=list(groups.values()),
        )

    @classmethod
    def delete_pingone_user(cls):
        p1_utils.delete_user(
            token_session=cls.p1_session,
            endpoint=cls.p1_environment_endpoints.users,
            name=cls.username,
        )

    def pingone_login(self):
        self.browser.get(ENV_UI_URL)
        # Wait for initial page load
        self.browser.implicitly_wait(10)
        self.browser.find_element(By.ID, "username").send_keys(self.username)
        self.browser.find_element(By.ID, "password").send_keys(self.password)
        self.browser.find_element(
            By.CSS_SELECTOR, 'button[data-id="submit-button"]'
        ).click()
        # Wait for post-login screen
        self.browser.implicitly_wait(10)
        try:
            # Handle verify email pop-up when presented
            if self.browser.find_element(
                By.CSS_SELECTOR, "[aria-label=verify-email-modal]"
            ):
                self.browser.find_element(
                    By.CSS_SELECTOR, '[aria-label="Close modal window"]'
                ).click()
        except selenium.common.exceptions.NoSuchElementException:
            pass

    @tenacity.retry(
        reraise=True,
        wait=tenacity.wait_fixed(5),
        before_sleep=tenacity.before_sleep_log(logger, logging.INFO),
        stop=tenacity.stop_after_attempt(100),
    )
    def wait_until_url_is_reachable(self, admin_console_url: str):
        try:
            warnings.filterwarnings(
                "ignore", category=urllib3.exceptions.InsecureRequestWarning
            )
            response = requests.get(
                admin_console_url, allow_redirects=True, verify=False
            )
            response.raise_for_status()
            warnings.resetwarnings()
        except requests.exceptions.HTTPError:
            raise

    def test_user_can_log_in_to_pingone(self):
        self.pingone_login()
        self.browser.implicitly_wait(10)
        # The content iframe on the home page displays the list of environments, have to switch or selenium can't see it

        try:
            iframe = self.browser.find_element(By.ID, "content-iframe")
            self.browser.switch_to.frame(iframe)
            title = self.browser.find_element(
                By.XPATH, "//div[contains(text(), 'Your Environments')]"
            )
            self.assertTrue(title.is_displayed())
        except selenium.common.exceptions.NoSuchElementException:
            self.fail(
                f"PingOne console 'Your Environments' page was not displayed when attempting to access {self.ENV_UI_URL}. Browser contents: {self.browser.page_source}"
            )
