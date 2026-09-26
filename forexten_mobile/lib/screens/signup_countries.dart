class SignupCountry {
  const SignupCountry(this.name, this.iso, this.dial);
  final String name;
  final String iso;
  final String dial;

  String get flag {
    if (iso.length != 2) return '';
    final a = iso.codeUnitAt(0) - 0x41 + 0x1F1E6;
    final b = iso.codeUnitAt(1) - 0x41 + 0x1F1E6;
    return String.fromCharCodes([a, b]);
  }
}

const signupCountries = <SignupCountry>[
  SignupCountry('Afghanistan', 'AF', '93'),
  SignupCountry('Albania', 'AL', '355'),
  SignupCountry('Algeria', 'DZ', '213'),
  SignupCountry('Argentina', 'AR', '54'),
  SignupCountry('Australia', 'AU', '61'),
  SignupCountry('Austria', 'AT', '43'),
  SignupCountry('Bahrain', 'BH', '973'),
  SignupCountry('Bangladesh', 'BD', '880'),
  SignupCountry('Belgium', 'BE', '32'),
  SignupCountry('Brazil', 'BR', '55'),
  SignupCountry('Canada', 'CA', '1'),
  SignupCountry('China', 'CN', '86'),
  SignupCountry('Egypt', 'EG', '20'),
  SignupCountry('France', 'FR', '33'),
  SignupCountry('Germany', 'DE', '49'),
  SignupCountry('Ghana', 'GH', '233'),
  SignupCountry('India', 'IN', '91'),
  SignupCountry('Indonesia', 'ID', '62'),
  SignupCountry('Italy', 'IT', '39'),
  SignupCountry('Japan', 'JP', '81'),
  SignupCountry('Jordan', 'JO', '962'),
  SignupCountry('Kenya', 'KE', '254'),
  SignupCountry('Kuwait', 'KW', '965'),
  SignupCountry('Lebanon', 'LB', '961'),
  SignupCountry('Malaysia', 'MY', '60'),
  SignupCountry('Mexico', 'MX', '52'),
  SignupCountry('Morocco', 'MA', '212'),
  SignupCountry('Netherlands', 'NL', '31'),
  SignupCountry('Nigeria', 'NG', '234'),
  SignupCountry('Oman', 'OM', '968'),
  SignupCountry('Pakistan', 'PK', '92'),
  SignupCountry('Philippines', 'PH', '63'),
  SignupCountry('Poland', 'PL', '48'),
  SignupCountry('Portugal', 'PT', '351'),
  SignupCountry('Qatar', 'QA', '974'),
  SignupCountry('Romania', 'RO', '40'),
  SignupCountry('Saudi Arabia', 'SA', '966'),
  SignupCountry('Singapore', 'SG', '65'),
  SignupCountry('South Africa', 'ZA', '27'),
  SignupCountry('Spain', 'ES', '34'),
  SignupCountry('Sweden', 'SE', '46'),
  SignupCountry('Switzerland', 'CH', '41'),
  SignupCountry('Turkey', 'TR', '90'),
  SignupCountry('Ukraine', 'UA', '380'),
  SignupCountry('United Arab Emirates', 'AE', '971'),
  SignupCountry('United Kingdom', 'GB', '44'),
  SignupCountry('United States', 'US', '1'),
  SignupCountry('Vietnam', 'VN', '84'),
];
