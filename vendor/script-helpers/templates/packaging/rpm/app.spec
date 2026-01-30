Name:           @APP_NAME@
Version:        @APP_VERSION@
Release:        @RPM_RELEASE@
Summary:        @APP_DESCRIPTION@
License:        @RPM_LICENSE@
URL:            @RPM_URL@
Source0:        %{name}-%{version}.tar.gz
BuildArch:      x86_64

@RPM_BUILD_REQUIRES_LINES@
@RPM_REQUIRES_LINES@

%description
@RPM_DESCRIPTION@

%prep
%autosetup -n %{name}-%{version}

%build
@APP_BUILD_CMD@

%install
rm -rf %{buildroot}
DESTDIR=%{buildroot} PREFIX=@APP_INSTALL_PREFIX@ @APP_INSTALL_CMD@

%files
@RPM_FILES@

%changelog
* @RPM_DATE@ @RPM_MAINTAINER@ - @APP_VERSION@-1
- Automated release.
