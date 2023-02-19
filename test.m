% pkg install -forge netcdf
pkg load netcdf

addpath ./m_map
% f = 'ATL09_20221012234137_03401701_005_02.h5.nc4';
% f = 'https://eosdap.hdfgroup.org:8080/opendap/data/NASAFILES/zoo/ATL09_20221012234137_03401701_005_02.h5'

f = 'https://n5eil02u.ecs.nsidc.org/opendap/ATLAS/ATL09.005/2022.10.12/ATL09_20221012000718_03251701_005_02.h5'
ncinfo(f)

lat = ncread(f, 'profile_1_high_rate_latitude');
lon = ncread(f, 'profile_1_high_rate_longitude');
data = ncread(f, 'profile_1_high_rate_apparent_surf_reflec');
dset = 'profile_1_high_rate_apparent_surf_reflec';
long_name = ncreadatt(f, dset, 'long_name')
units = ncreadatt(f, dset, 'units')

% Plot data.
clf;
cmap =jet();

colormap(cmap);
m_proj('miller');
m_scatter(lon, lat, 1, data);
shading flat;
m_grid();
m_coast('color', 'black');
h = colorbar();

% Annotate the plot.
title_str = ['ATL09' '\n', long_name];
set(get(h, 'title'), 'string', units);
title(sprintf(title_str), 'Interpreter', 'None', 'FontSize', 10);
print('-dpng', '-r300', ['ATL09', '.m.png']);
