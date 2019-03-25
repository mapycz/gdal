#!/usr/bin/env pytest
###############################################################################
# $Id$
#
# Project:  GDAL/OGR Test Suite
# Purpose:  ContourGenerate() testing
# Author:   Even Rouault <even dot rouault @ mines-paris dot org>
#
###############################################################################
# Copyright (c) 2010, Even Rouault <even dot rouault at mines-paris dot org>
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included
# in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
# OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.
###############################################################################

import array
import os


from osgeo import gdal
from osgeo import ogr
import ogrtest
import pytest

###############################################################################
# Test with -a and -i options


def test_contour_1():

    try:
        os.remove('tmp/contour.shp')
    except OSError:
        pass
    try:
        os.remove('tmp/contour.dbf')
    except OSError:
        pass
    try:
        os.remove('tmp/contour.shx')
    except OSError:
        pass

    drv = gdal.GetDriverByName('GTiff')
    wkt = 'GEOGCS[\"WGS 84\",DATUM[\"WGS_1984\",SPHEROID[\"WGS 84\",6378137,298.257223563,AUTHORITY[\"EPSG\",\"7030\"]],AUTHORITY[\"EPSG\",\"6326\"]],PRIMEM[\"Greenwich\",0,AUTHORITY[\"EPSG\",\"8901\"]],UNIT[\"degree\",0.0174532925199433,AUTHORITY[\"EPSG\",\"9108\"]],AUTHORITY[\"EPSG\",\"4326\"]]'

    size = 160
    precision = 1.0 / size

    ds = drv.Create('tmp/gdal_contour.tif', size, size, 1)
    ds.SetProjection(wkt)
    ds.SetGeoTransform([1, precision, 0, 50, 0, -precision])

    raw_data = array.array('h', [10 for i in range(int(size / 2))]).tostring()
    for i in range(int(size / 2)):
        ds.WriteRaster(int(size / 4), i + int(size / 4), int(size / 2), 1, raw_data,
                       buf_type=gdal.GDT_Int16,
                       band_list=[1])

    raw_data = array.array('h', [20 for i in range(int(size / 2))]).tostring()
    for i in range(int(size / 4)):
        ds.WriteRaster(int(size / 4) + int(size / 8), i + int(size / 4) + int(size / 8), int(size / 4), 1, raw_data,
                       buf_type=gdal.GDT_Int16,
                       band_list=[1])

    raw_data = array.array('h', [25 for i in range(int(size / 4))]).tostring()
    for i in range(int(size / 8)):
        ds.WriteRaster(int(size / 4) + int(size / 8) + int(size / 16), i + int(size / 4) + int(size / 8) + int(size / 16), int(size / 8), 1, raw_data,
                       buf_type=gdal.GDT_Int16,
                       band_list=[1])

    ogr_ds = ogr.GetDriverByName('ESRI Shapefile').CreateDataSource('tmp/contour.shp')
    ogr_lyr = ogr_ds.CreateLayer('contour')
    field_defn = ogr.FieldDefn('ID', ogr.OFTInteger)
    ogr_lyr.CreateField(field_defn)
    field_defn = ogr.FieldDefn('elev', ogr.OFTReal)
    ogr_lyr.CreateField(field_defn)

    gdal.ContourGenerate(ds.GetRasterBand(1), 10, 0, [], 0, 0, ogr_lyr, 0, 1)

    ds = None

    expected_envelopes = [[1.25, 1.75, 49.25, 49.75],
                          [1.25 + 0.125, 1.75 - 0.125, 49.25 + 0.125, 49.75 - 0.125]]
    expected_height = [10, 20]

    lyr = ogr_ds.ExecuteSQL("select * from contour order by elev asc")

    assert lyr.GetFeatureCount() == len(expected_envelopes)

    i = 0
    feat = lyr.GetNextFeature()
    while feat is not None:
        envelope = feat.GetGeometryRef().GetEnvelope()
        assert feat.GetField('elev') == expected_height[i]
        for j in range(4):
            if abs(expected_envelopes[i][j] - envelope[j]) > precision / 2 * 1.001:
                print('i=%d, wkt=%s' % (i, feat.GetGeometryRef().ExportToWkt()))
                print(feat.GetGeometryRef().GetEnvelope())
                pytest.fail('%f, %f' % (expected_envelopes[i][j] - envelope[j], precision / 2))
        i = i + 1
        feat = lyr.GetNextFeature()

    ogr_ds.ReleaseResultSet(lyr)
    ogr_ds.Destroy()

###############################################################################
# Test with -fl option and -3d option


def test_contour_2():

    try:
        os.remove('tmp/contour.shp')
    except OSError:
        pass
    try:
        os.remove('tmp/contour.dbf')
    except OSError:
        pass
    try:
        os.remove('tmp/contour.shx')
    except OSError:
        pass

    ogr_ds = ogr.GetDriverByName('ESRI Shapefile').CreateDataSource('tmp/contour.shp')
    ogr_lyr = ogr_ds.CreateLayer('contour', geom_type=ogr.wkbLineString25D)
    field_defn = ogr.FieldDefn('ID', ogr.OFTInteger)
    ogr_lyr.CreateField(field_defn)
    field_defn = ogr.FieldDefn('elev', ogr.OFTReal)
    ogr_lyr.CreateField(field_defn)

    ds = gdal.Open('tmp/gdal_contour.tif')
    gdal.ContourGenerate(ds.GetRasterBand(1), 0, 0, [10, 20, 25], 0, 0, ogr_lyr, 0, 1)
    ds = None

    size = 160
    precision = 1. / size

    expected_envelopes = [[1.25, 1.75, 49.25, 49.75],
                          [1.25 + 0.125, 1.75 - 0.125, 49.25 + 0.125, 49.75 - 0.125],
                          [1.25 + 0.125 + 0.0625, 1.75 - 0.125 - 0.0625, 49.25 + 0.125 + 0.0625, 49.75 - 0.125 - 0.0625]]
    expected_height = [10, 20, 25, 10000]

    lyr = ogr_ds.ExecuteSQL("select * from contour order by elev asc")

    assert lyr.GetFeatureCount() == len(expected_envelopes)

    i = 0
    feat = lyr.GetNextFeature()
    while feat is not None:
        assert feat.GetGeometryRef().GetZ(0) == expected_height[i]
        envelope = feat.GetGeometryRef().GetEnvelope()
        assert feat.GetField('elev') == expected_height[i]
        for j in range(4):
            if abs(expected_envelopes[i][j] - envelope[j]) > precision / 2 * 1.001:
                print('i=%d, wkt=%s' % (i, feat.GetGeometryRef().ExportToWkt()))
                print(feat.GetGeometryRef().GetEnvelope())
                pytest.fail('%f, %f' % (expected_envelopes[i][j] - envelope[j], precision / 2))
        i = i + 1
        feat = lyr.GetNextFeature()

    ogr_ds.ReleaseResultSet(lyr)
    ogr_ds.Destroy()

###############################################################################
#


def test_contour_real_world_case():

    ogr_ds = ogr.GetDriverByName('Memory').CreateDataSource('')
    ogr_lyr = ogr_ds.CreateLayer('contour', geom_type=ogr.wkbLineString)
    field_defn = ogr.FieldDefn('ID', ogr.OFTInteger)
    ogr_lyr.CreateField(field_defn)
    field_defn = ogr.FieldDefn('elev', ogr.OFTReal)
    ogr_lyr.CreateField(field_defn)

    ds = gdal.Open('data/contour_in.tif')
    gdal.ContourGenerate(ds.GetRasterBand(1), 10, 0, [], 0, 0, ogr_lyr, 0, 1)
    ds = None

    ogr_lyr.SetAttributeFilter('elev = 330')
    assert ogr_lyr.GetFeatureCount() == 1
    f = ogr_lyr.GetNextFeature()
    assert ogrtest.check_feature_geometry(f, 'LINESTRING (4.50497512437811 11.5,4.5 11.501996007984,3.5 11.8333333333333,2.5 11.5049751243781,2.490099009901 11.5,2.0 10.5,2.5 10.1666666666667,3.0 9.5,3.5 9.21428571428571,4.49800399201597 8.5,4.5 8.49857346647646,5.5 8.16666666666667,6.5 8.0,7.5 8.0,8.0 7.5,8.5 7.0,9.490099009901 6.5,9.5 6.49667774086379,10.5 6.16666666666667,11.4950248756219 5.5,11.5 5.49833610648919,12.5 5.49667774086379,13.5 5.49800399201597,13.501996007984 5.5,13.5 5.50199600798403,12.501996007984 6.5,12.5 6.50142653352354,11.5 6.509900990099,10.509900990099 7.5,10.5 7.50142653352354,9.5 7.9,8.50332225913621 8.5,8.5 8.50249376558603,7.83333333333333 9.5,7.5 10.0,7.0 10.5,6.5 10.7857142857143,5.5 11.1666666666667,4.50497512437811 11.5)', 0.01) == 0

# Test with -p option (polygonize)

def test_contour_3():

    try:
        os.remove('tmp/contour.shp')
    except OSError:
        pass
    try:
        os.remove('tmp/contour.dbf')
    except OSError:
        pass
    try:
        os.remove('tmp/contour.shx')
    except OSError:
        pass

    ogr_ds = ogr.GetDriverByName('ESRI Shapefile').CreateDataSource('tmp/contour.shp')
    ogr_lyr = ogr_ds.CreateLayer('contour', geom_type=ogr.wkbMultiPolygon)
    field_defn = ogr.FieldDefn('ID', ogr.OFTInteger)
    ogr_lyr.CreateField(field_defn)
    field_defn = ogr.FieldDefn('elevMin', ogr.OFTReal)
    ogr_lyr.CreateField(field_defn)
    field_defn = ogr.FieldDefn('elevMax', ogr.OFTReal)
    ogr_lyr.CreateField(field_defn)

    ds = gdal.Open('tmp/gdal_contour.tif')
    #gdal.ContourGenerateEx(ds.GetRasterBand(1), 0, 0, 0, [10, 20, 25], 0, 0, ogr_lyr, 0, 1, 1)
    gdal.ContourGenerateEx(ds.GetRasterBand(1), ogr_lyr, options = [ "FIXED_LEVELS=10,20,25",
                                                                     "ID_FIELD=0",
                                                                     "ELEV_FIELD_MIN=1",
                                                                     "ELEV_FIELD_MAX=2",
                                                                     "POLYGONIZE=TRUE" ] )
    ds = None

    size = 160
    precision = 1. / size

    expected_envelopes = [[1.0, 2.0, 49.0, 50.0],
                          [1.25, 1.75, 49.25, 49.75],
                          [1.25 + 0.125, 1.75 - 0.125, 49.25 + 0.125, 49.75 - 0.125],
                          [1.25 + 0.125 + 0.0625, 1.75 - 0.125 - 0.0625, 49.25 + 0.125 + 0.0625, 49.75 - 0.125 - 0.0625]]
    expected_height = [10, 20, 25, 10000]

    lyr = ogr_ds.ExecuteSQL("select * from contour order by elevMin asc")

    assert lyr.GetFeatureCount() == len(expected_envelopes)

    i = 0
    feat = lyr.GetNextFeature()
    while feat is not None:
        if i < 3 and feat.GetField('elevMax') != expected_height[i]:
            pytest.fail('Got %f as z. Expected %f' % (feat.GetField('elevMax'), expected_height[i]))
        elif i > 0 and i < 3 and feat.GetField('elevMin') != expected_height[i-1]:
            pytest.fail('Got %f as z. Expected %f' % (feat.GetField('elevMin'), expected_height[i-1]))

        envelope = feat.GetGeometryRef().GetEnvelope()
        for j in range(4):
            if abs(expected_envelopes[i][j] - envelope[j]) > precision / 2 * 1.001:
                print('i=%d, wkt=%s' % (i, feat.GetGeometryRef().ExportToWkt()))
                print(feat.GetGeometryRef().GetEnvelope())
                pytest.fail('%f, %f' % (expected_envelopes[i][j] - envelope[j], precision / 2))
        i = i + 1
        feat = lyr.GetNextFeature()

    ogr_ds.ReleaseResultSet(lyr)
    ogr_ds.Destroy()

def test_contour_smooth():

    try:
        os.remove('tmp/contour_smooth.shp')
    except OSError:
        pass
    try:
        os.remove('tmp/contour_smooth.dbf')
    except OSError:
        pass
    try:
        os.remove('tmp/contour_smooth.shx')
    except OSError:
        pass

    ogr_ds = ogr.GetDriverByName('ESRI Shapefile').CreateDataSource('tmp/contour_smooth.shp')
    ogr_lyr = ogr_ds.CreateLayer('contour', geom_type=ogr.wkbLineString)
    field_defn = ogr.FieldDefn('ID', ogr.OFTInteger)
    ogr_lyr.CreateField(field_defn)
    field_defn = ogr.FieldDefn('elev', ogr.OFTReal)
    ogr_lyr.CreateField(field_defn)

    ds = gdal.Open('data/contour_in.tif')

    gdal.ContourGenerateEx(ds.GetRasterBand(1), ogr_lyr, options=[
        "LEVEL_INTERVAL=10",
        "ID_FIELD=0",
        "ELEV_FIELD=1",
        "ELEV_SMOOTH_CYCLES=2",
        "ELEV_SMOOTH_LOOP_SUPPORT=YES",
        "ELEV_SMOOTH_LOOK_AHEAD=7",
        "ELEV_SMOOTH_SLIDE=1.0",
        "ELEV_SMOOTH_MIN_POINTS=15",
    ])

    ogr_lyr.SetAttributeFilter('elev = 330')
    assert ogr_lyr.GetFeatureCount() == 1
    f = ogr_lyr.GetNextFeature()
    assert ogrtest.check_feature_geometry(f, 'LINESTRING (4.90136055442183 11.0359573257531,4.35374145578244 11.1287658818269,3.86734684693897 11.113702714723,3.48979577142883 10.9829932891156,3.25510183877584 10.7604471105927,3.17346917653093 10.4494655579203,3.27551000408191 10.0932944957726,3.54081613775534 9.71331389961126,3.93877534285734 9.33333330344996,4.45918352755118 8.95481042711375,5.06122435306138 8.60349843513127,5.72448966836749 8.27259461564636,6.4285712897961 7.9689016805152,7.14285697244922 7.6652087555881,7.83673449183703 7.35471312657936,8.5204079448983 7.0442174907679,9.20408139795956 6.74829913075817,9.86734672857176 6.47278893401374,10.5102038959187 6.21768691530624,11.0918365775513 6.01020394421778,11.5918366265308 5.87414954237131,12.0102040224491 5.80952372896018,12.295918367347 5.8265305822157,12.4183674061224 5.91496600777444,12.377551110204 6.07278918843522,12.1530613517005 6.31224500719125,11.8061226054419 6.58571443649149,11.3435375904759 6.90000018649144,10.7993199224487 7.26530630553909,10.2244899738092 7.65102058104933,9.62925186190452 8.06297391370243,9.03401375408142 8.49261432118546,8.45918380612228 8.92225473275012,7.88435386224476 9.37230330145765,7.31632663945567 9.80874643090375,6.72789125340128 10.2043732542274,6.11904769387751 10.5591837510204,5.50000004251702 10.8411079533527,4.90136055442183 11.0359573257531)', 0.01) == 0

    ogr_lyr.SetAttributeFilter('elev = 320')
    assert ogr_lyr.GetFeatureCount() == 2

    ogr_ds.Destroy()

###############################################################################
# Cleanup


def test_contour_cleanup():
    ogr.GetDriverByName('ESRI Shapefile').DeleteDataSource('tmp/contour.shp')
    ogr.GetDriverByName('ESRI Shapefile').DeleteDataSource('tmp/contour_smooth.shp')
    try:
        os.remove('tmp/gdal_contour.tif')
    except OSError:
        pass

    



